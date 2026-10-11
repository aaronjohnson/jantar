defmodule BeamHud.Render.Native do
  @moduledoc """
  The Rust renderer (native/hud_render), a NIF built by Rustler. Each function
  here is replaced by the native one when the library loads; the bodies only
  run if it failed to load.

  Drawing runs on dirty CPU schedulers, so a 30 ms frame doesn't stall the
  normal schedulers that run every other process.
  """
  use Rustler, otp_app: :beam_hud, crate: "hud_render", mode: :release

  def new(_regular_ttf, _bold_ttf), do: err()
  def render_png(_renderer, _display_list, _path), do: err()
  def open_fb(_path, _width, _height, _stride), do: err()
  def render_fb(_renderer, _fb, _display_list), do: err()
  def invalidate(_fb), do: err()
  def kd_mode(_tty, _graphics?), do: err()
  def panic_demo, do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
