defmodule BeamHud.Render.DisplayList do
  @moduledoc """
  The drawing commands a frame is made of, encoded as one binary. The BEAM
  side (`BeamHud.Frame`) decides everything: layout, colours, every dial point
  (using the Gleam `polar` module), so the two backends (the Rust NIF and the
  cairo Port) only rasterise. That keeps one source of truth for the maths and
  makes the two pictures comparable.

  Data crosses into native code as this single binary: no per-value term
  decoding, just a byte reader on the other side.

  ## Format (all numbers little-endian)

      header   "HUD1" width:u32 height:u32
      then ops until the end, each starting with an opcode byte:

      0x01 FILL       rgb:u32                              whole canvas
      0x02 RECTS      n:u32, n x (x y w h:f32, rgb:u32)    filled rectangles
      0x03 LINE       x0 y0 x1 y1 width:f32, rgb:u32       butt caps
      0x04 CIRCLES    n:u32, n x (cx cy r:f32, rgb:u32)    filled, in order
      0x05 RING       cx cy r width:f32, rgb:u32           stroked circle
      0x06 ARC        cx cy r a0 a1 width:f32, rgb:u32     stroked, butt caps
      0x07 RRECT      x0 y0 x1 y1 radius:f32, rgb:u32      filled rounded rect
      0x08 TEXT       x y:f32, halign:u8, valign:u8, n:u8,
                      n x (size:f32, bold:u8, rgb:u32, len:u16, utf8 bytes)
      0x09 POLYLINE   width:f32, rgb:u32, n:u32, n x (x y:f32)
      0x0A SEGMENTS   width:f32, n:u32, n x (x0 y0 x1 y1:f32, rgb:u32)

  Colours are opaque 0xRRGGBB: fading is pre-blended against the background
  here, as hud does. Angles are radians, clockwise on screen from 3 o'clock,
  drawn from a0 to a1 (a1 > a0). Radii of stroked shapes are the centre of the
  stroke.

  TEXT draws a run of differently styled parts side by side, positioned as a
  whole: halign 0 = left edge at x, 1 = centred on x, 2 = right edge at x;
  valign 0 = ascender at y (top), 1 = middle of ascender..descender at y,
  2 = descender at y (bottom). The font is DejaVu Sans Mono, regular or bold;
  size is the em size in pixels.
  """

  import Bitwise

  @type rgb :: non_neg_integer
  @type op :: iodata

  @doc "A complete display list for a width x height frame."
  @spec encode(pos_integer, pos_integer, [op]) :: binary
  def encode(width, height, ops) do
    IO.iodata_to_binary(["HUD1", <<width::32-little, height::32-little>>, ops])
  end

  def fill(rgb), do: <<0x01, rgb::32-little>>

  @doc "Rectangles `{x, y, w, h, rgb}`."
  def rects([]), do: []

  def rects(rects) do
    [
      <<0x02, length(rects)::32-little>>
      | for(
          {x, y, w, h, c} <- rects,
          do: <<f(x)::binary, f(y)::binary, f(w)::binary, f(h)::binary, c::32-little>>
        )
    ]
  end

  def line(x0, y0, x1, y1, width, rgb),
    do:
      <<0x03, f(x0)::binary, f(y0)::binary, f(x1)::binary, f(y1)::binary, f(width)::binary,
        rgb::32-little>>

  @doc "Filled circles `{cx, cy, r, rgb}`, drawn in order."
  def circles([]), do: []

  def circles(circles) do
    [
      <<0x04, length(circles)::32-little>>
      | for(
          {x, y, r, c} <- circles,
          do: <<f(x)::binary, f(y)::binary, f(r)::binary, c::32-little>>
        )
    ]
  end

  def ring(cx, cy, r, width, rgb),
    do: <<0x05, f(cx)::binary, f(cy)::binary, f(r)::binary, f(width)::binary, rgb::32-little>>

  def arc(cx, cy, r, a0, a1, width, rgb),
    do:
      <<0x06, f(cx)::binary, f(cy)::binary, f(r)::binary, f(a0)::binary, f(a1)::binary,
        f(width)::binary, rgb::32-little>>

  def rrect(x0, y0, x1, y1, radius, rgb),
    do:
      <<0x07, f(x0)::binary, f(y0)::binary, f(x1)::binary, f(y1)::binary, f(radius)::binary,
        rgb::32-little>>

  @halign %{left: 0, center: 1, right: 2}
  @valign %{top: 0, middle: 1, bottom: 2}

  @doc """
  A run of text parts `{text, size, bold?, rgb}` anchored at (x, y), e.g.
  `text(cx, y, :center, :top, [{"CPU", 11.0, true, 0xB58900}])`.
  """
  def text(x, y, halign, valign, parts) do
    parts = Enum.reject(parts, fn {t, _, _, _} -> t == "" end)

    if parts == [] do
      []
    else
      [
        <<0x08, f(x)::binary, f(y)::binary, @halign[halign], @valign[valign], length(parts)>>
        | for {t, size, bold, c} <- parts do
            <<f(size)::binary, if(bold, do: 1, else: 0), c::32-little, byte_size(t)::16-little,
              t::binary>>
          end
      ]
    end
  end

  @doc "A line through `[{x, y}]`."
  def polyline(points, _width, _rgb) when length(points) < 2, do: []

  def polyline(points, width, rgb) do
    [
      <<0x09, f(width)::binary, rgb::32-little, length(points)::32-little>>
      | for({x, y} <- points, do: <<f(x)::binary, f(y)::binary>>)
    ]
  end

  @doc "Line segments `{x0, y0, x1, y1, rgb}` of one width."
  def segments([], _width), do: []

  def segments(segs, width) do
    [
      <<0x0A, f(width)::binary, length(segs)::32-little>>
      | for(
          {x0, y0, x1, y1, c} <- segs,
          do: <<f(x0)::binary, f(y0)::binary, f(x1)::binary, f(y1)::binary, c::32-little>>
        )
    ]
  end

  # ------------------------------------------------------------------ colours

  @doc "\"#93a1a1\" -> 0x93A1A1"
  def hex("#" <> h), do: String.to_integer(h, 16)

  @doc "Colour `a` at opacity `t` over `b`, pre-blended (hud's mix())."
  def mix(a, b, t) do
    ch = fn c, shift -> c >>> shift &&& 0xFF end

    for shift <- [16, 8, 0], reduce: 0 do
      acc ->
        v = trunc(ch.(a, shift) * t + ch.(b, shift) * (1 - t) + 0.5)
        acc ||| min(255, max(0, v)) <<< shift
    end
  end

  defp f(x), do: <<x / 1::float-32-little>>
end
