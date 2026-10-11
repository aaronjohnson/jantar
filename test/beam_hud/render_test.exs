defmodule BeamHud.RenderTest do
  @moduledoc """
  Both backends draw the deterministic demo frame (`BeamHud.Frame.Demo`):
  into a PNG (checked by its header) and into a stand-in framebuffer file,
  whose raw XRGB8888 pixels are easy to inspect: background colour, dials
  that aren't empty, and the two backends agreeing on the picture.
  """
  use ExUnit.Case, async: true

  alias BeamHud.{Frame, Render}
  alias BeamHud.Render.DisplayList, as: DL

  @moduletag :tmp_dir
  @w 720
  @h 480

  defp demo_list(theme \\ :dark) do
    {list, _meta} =
      Frame.build(Frame.Demo.snapshot(),
        width: @w,
        height: @h,
        theme: theme,
        host: "test",
        clock: "12:00:00"
      )

    list
  end

  # Draw into a stand-in framebuffer file and return its pixels.
  defp draw_fb(backend, dir, list) do
    path = Path.join(dir, "fb-#{backend}")
    File.write!(path, :binary.copy(<<0>>, @w * @h * 4))
    server = start_supervised!({Render.module(backend), []}, id: backend)
    :ok = Render.open_fb(server, path, @w, @h, @w * 4)
    assert {:ok, _us, bands} = Render.fb(server, list)
    # A first frame writes every 16-row band.
    assert bands == div(@h + 15, 16)
    # The same frame again changes nothing.
    assert {:ok, _us, 0} = Render.fb(server, list)
    File.read!(path)
  end

  # The pixel at (x, y) as 0xRRGGBB (the file is B, G, R, X per pixel).
  defp pixel(fb, x, y) do
    <<b, g, r, _x>> = binary_part(fb, (y * @w + x) * 4, 4)
    r * 65_536 + g * 256 + b
  end

  # How many pixels in a box differ from the background.
  defp ink(fb, {x0, y0, x1, y1}, bg) do
    for y <- y0..y1, x <- x0..x1, pixel(fb, x, y) != bg, reduce: 0, do: (n -> n + 1)
  end

  for backend <- [:rust, :cairo] do
    test "#{backend}: a PNG of the right size", %{tmp_dir: dir} do
      server = start_supervised!({Render.module(unquote(backend)), []})
      path = Path.join(dir, "frame.png")
      assert {:ok, us} = Render.png(server, demo_list(), path)
      assert us > 0
      # PNG signature, then the IHDR chunk with width and height.
      assert <<137, "PNG", 13, 10, 26, 10, _len::32, "IHDR", @w::32, @h::32, _::binary>> =
               File.read!(path)
    end

    test "#{backend}: background, header and dials in the framebuffer", %{tmp_dir: dir} do
      fb = draw_fb(unquote(backend), dir, demo_list())
      bg = BeamHud.Theme.palette(:dark).bg
      assert pixel(fb, 0, 0) == bg
      assert pixel(fb, @w - 1, @h - 1) == bg
      # The header text ("beam-hud ...") at the top left.
      assert ink(fb, {8, 3, 120, 15}, bg) > 50
      # The CPU rings (first tile) and the LOAD dial (last tile) have content.
      assert ink(fb, {40, 25, 140, 125}, bg) > 1000
      assert ink(fb, {480, 320, 560, 400}, bg) > 300
    end

    test "#{backend}: light theme", %{tmp_dir: dir} do
      fb = draw_fb(unquote(backend), dir, demo_list(:light))
      assert pixel(fb, 0, 0) == BeamHud.Theme.palette(:light).bg
    end
  end

  test "the two backends draw the same picture", %{tmp_dir: dir} do
    list = demo_list()
    rust = draw_fb(:rust, dir, list)
    cairo = draw_fb(:cairo, dir, list)

    # Compare pixel by pixel, allowing small differences in anti-aliasing.
    differing =
      for i <- 0..(@w * @h - 1), reduce: 0 do
        n ->
          <<b1, g1, r1, _>> = binary_part(rust, i * 4, 4)
          <<b2, g2, r2, _>> = binary_part(cairo, i * 4, 4)
          if abs(b1 - b2) + abs(g1 - g2) + abs(r1 - r2) > 96, do: n + 1, else: n
      end

    # Text hinting differs a little; shapes should agree almost everywhere.
    assert differing / (@w * @h) < 0.02, "#{differing} pixels differ"
  end

  test "a malformed display list is an error, not a crash" do
    for backend <- [:rust, :cairo] do
      server = start_supervised!({Render.module(backend), []}, id: backend)

      assert {:error, _} =
               Render.png(
                 server,
                 "HUD1" <> <<10::32-little, 10::32-little, 0x02, 5::32-little>>,
                 "/dev/null"
               )

      assert {:error, _} = Render.png(server, "nope", "/dev/null")
      assert {:error, _} = Render.png(server, DL.encode(10, 10, [<<0x7F>>]), "/dev/null")
    end
  end

  test "display list encoding" do
    list =
      DL.encode(3, 2, [DL.fill(0x112233), DL.text(1, 2, :center, :top, [{"", 10, false, 0}])])

    # Empty text parts are dropped, and a run with none disappears.
    assert list == "HUD1" <> <<3::32-little, 2::32-little, 0x01, 0x112233::32-little>>
    assert DL.mix(0xFFFFFF, 0x000000, 0.5) == 0x808080
    assert DL.mix(0x123456, 0xABCDEF, 1.0) == 0x123456
    assert DL.hex("#002b36") == 0x002B36
  end

  test "the demo frame uses bands for dense series and lists its sensors" do
    {list, meta} =
      Frame.build(Frame.Demo.snapshot(),
        width: 1440,
        height: 960,
        theme: :dark,
        host: "h",
        clock: "c"
      )

    assert :cpu in meta.sensors and :net in meta.sensors
    # SEGMENTS (0x0A, the min..max bands) appear; the list is well under a megabyte.
    assert :binary.match(list, <<0x0A>>) != :nomatch
    assert byte_size(list) < 1_000_000
  end
end
