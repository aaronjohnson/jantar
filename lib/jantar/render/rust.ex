defmodule Jantar.Render.Rust do
  @moduledoc """
  The Rust backend: a process holding the NIF's resources (fonts and the
  mapped framebuffer). The drawing itself runs on a dirty CPU scheduler,
  called from this process.

  A Rust panic is caught by Rustler and arrives here as an exception; but a
  real memory fault in native code would take the whole VM down. That is
  the price of running in-process, and the reason for the cairo Port.
  """
  use GenServer
  alias Jantar.Render.Native

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(_opts) do
    {regular, bold} = Jantar.Render.fonts()
    {:ok, renderer} = Native.new(regular, bold)
    {:ok, %{renderer: renderer, fb: nil}}
  end

  @impl true
  def handle_call({:png, list, path}, _from, s),
    do: {:reply, Native.render_png(s.renderer, list, path), s}

  def handle_call({:open_fb, path, w, h, stride}, _from, s) do
    case Native.open_fb(path, w, h, stride) do
      {:ok, fb} -> {:reply, :ok, %{s | fb: fb}}
      error -> {:reply, error, s}
    end
  end

  def handle_call({:fb, _list}, _from, %{fb: nil} = s),
    do: {:reply, {:error, "no framebuffer open"}, s}

  def handle_call({:fb, list}, _from, s) do
    reply =
      case Native.render_fb(s.renderer, s.fb, list) do
        {:ok, {us, bands}} -> {:ok, us, bands}
        error -> error
      end

    {:reply, reply, s}
  end

  def handle_call(:invalidate, _from, s) do
    if s.fb, do: Native.invalidate(s.fb)
    {:reply, :ok, s}
  end

  def handle_call({:kd_mode, tty, graphics?}, _from, s),
    do: {:reply, Native.kd_mode(tty, graphics?), s}
end
