defmodule Jantar.Render do
  @moduledoc """
  The renderer backends and their common interface.

  A backend is a process that draws display lists (`Jantar.Render.DisplayList`):

    * `Jantar.Render.Rust`  - the Rust NIF (tiny-skia + fontdue), in the VM
    * `Jantar.Render.Cairo` - the C program (cairo + FreeType) as a Port, in
      its own OS process

  Both answer the same calls, so the display can use either:

      {:ok, pid} = Jantar.Render.start_link(:rust)
      {:ok, us} = Jantar.Render.png(pid, list, "frame.png")
      :ok = Jantar.Render.open_fb(pid, "/dev/fb0", 2880, 1920, 11520)
      {:ok, us, bands} = Jantar.Render.fb(pid, list)
  """

  @backends %{rust: Jantar.Render.Rust, cairo: Jantar.Render.Cairo}

  @doc "The module for a backend name (:rust or :cairo)."
  def module(name), do: Map.fetch!(@backends, name)

  def start_link(name, opts \\ []), do: module(name).start_link(opts)

  @doc "Draw a display list into a PNG file; returns the drawing time in µs."
  def png(server, list, path), do: GenServer.call(server, {:png, list, path}, 30_000)

  @doc "Map a framebuffer (or a stand-in file) for `fb/2`."
  def open_fb(server, path, width, height, stride),
    do: GenServer.call(server, {:open_fb, path, width, height, stride}, 30_000)

  @doc "Draw into the framebuffer; returns µs and the number of 16-row bands written."
  def fb(server, list), do: GenServer.call(server, {:fb, list}, 30_000)

  @doc "Write the whole screen next time (after a VT switch)."
  def invalidate(server), do: GenServer.call(server, :invalidate)

  @doc "KDSETMODE on a tty: graphics (true) or text (false)."
  def kd_mode(server, tty, graphics?), do: GenServer.call(server, {:kd_mode, tty, graphics?})

  @doc """
  The regular and bold DejaVu Sans Mono files: from `config :jantar,
  font_dir:`, `$JANTAR_FONT_DIR` (set by the devShell), the system profile, or
  any dejavu-fonts in the Nix store.
  """
  def fonts do
    dirs =
      [
        Application.get_env(:jantar, :font_dir),
        System.get_env("JANTAR_FONT_DIR"),
        "/run/current-system/sw/share/X11/fonts",
        "/run/current-system/sw/share/fonts/truetype"
      ] ++ Path.wildcard("/nix/store/*-dejavu-fonts-*/share/fonts/truetype")

    dir =
      Enum.find(dirs, fn d -> d && File.exists?(Path.join(d, "DejaVuSansMono.ttf")) end) ||
        raise "DejaVu Sans Mono not found; set JANTAR_FONT_DIR"

    {Path.join(dir, "DejaVuSansMono.ttf"), Path.join(dir, "DejaVuSansMono-Bold.ttf")}
  end

  @doc """
  The framebuffer's geometry from sysfs: `%{width:, height:, stride:}`
  (32 bits per pixel, XRGB8888, is assumed and checked).
  """
  def fb_geometry(sys \\ "/sys/class/graphics/fb0") do
    read = fn f -> File.read!(Path.join(sys, f)) |> String.trim() end
    [w, h] = read.("virtual_size") |> String.split(",") |> Enum.map(&String.to_integer/1)
    bpp = String.to_integer(read.("bits_per_pixel"))
    if bpp != 32, do: raise("#{sys}: #{bpp} bits per pixel; only 32 is supported")
    %{width: w, height: h, stride: String.to_integer(read.("stride"))}
  end
end
