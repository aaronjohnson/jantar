defmodule BeamHud.Display.Ticker do
  @moduledoc """
  Draws frames while the dashboard's VT is the one on screen, and nothing
  otherwise.

    * Every 500 ms it reads which VT is in the foreground
      (/sys/class/tty/tty0/active, e.g. "tty12"): one small file read.
    * On becoming visible: `BeamHud.Mode` visible, KD_GRAPHICS on the tty (so
      the console stops drawing text over us), and a full redraw: whatever
      was on screen before is unknown.
    * While visible: a frame (snapshot History, build the display list, draw)
      at the pace of the fastest sensor behind the panels on screen: 4 fps
      while the 250 ms CPU dial is up, 1 fps if only slow series were. Capped
      by `:max_fps`, and by `:battery_max_fps` on battery.
    * On becoming hidden, or on shutdown: KD_TEXT, Mode not visible. The
      sensors keep collecting either way.
  """
  use GenServer
  require Logger

  alias BeamHud.{Frame, Mode, Render, Sensor, SensorSupervisor}

  @poll_ms 500
  @backend BeamHud.Display.Backend

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Counters for tests and `mix hud.fb`: frames drawn, last draw time, visibility."
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    # So terminate/2 runs on shutdown and can give the console back.
    Process.flag(:trap_exit, true)

    fb_path = Keyword.get(opts, :fb, "/dev/fb0")
    geometry = geometry(fb_path, opts[:size])
    :ok = Render.open_fb(@backend, fb_path, geometry.width, geometry.height, geometry.stride)

    tty = Keyword.get(opts, :tty, "/dev/tty12")

    state = %{
      tty: tty,
      vt: Path.basename(tty),
      active_file: Keyword.get(opts, :active_file, "/sys/class/tty/tty0/active"),
      kd_mode: Keyword.get(opts, :kd_mode, String.starts_with?(fb_path, "/dev/")),
      width: geometry.width,
      height: geometry.height,
      label: Keyword.get(opts, :label, Atom.to_string(Keyword.get(opts, :backend, :rust))),
      max_fps: Keyword.get(opts, :max_fps, 4),
      battery_max_fps: Keyword.get(opts, :battery_max_fps, 2),
      visible: false,
      frame_timer: nil,
      frames: 0,
      last_draw_us: nil,
      last_build_us: nil,
      interval_ms: nil
    }

    # Hidden until the poll finds our VT in front.
    Mode.set(:visible, false)
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    active = foreground_vt(state.active_file) == state.vt

    state =
      cond do
        active and not state.visible -> show(state)
        state.visible and not active -> hide(state)
        true -> state
      end

    {:noreply, state}
  end

  def handle_info(:frame, %{visible: false} = state), do: {:noreply, %{state | frame_timer: nil}}

  def handle_info(:frame, state) do
    {build_us, {list, meta}} =
      :timer.tc(fn ->
        Frame.build(Frame.snapshot(),
          width: state.width,
          height: state.height,
          label: state.label
        )
      end)

    state =
      case Render.fb(@backend, list) do
        {:ok, draw_us, _bands} ->
          %{state | frames: state.frames + 1, last_draw_us: draw_us, last_build_us: build_us}

        {:error, reason} ->
          tap(state, fn _ -> Logger.warning("frame not drawn: #{inspect(reason)}") end)
      end

    interval = frame_interval(meta.sensors, state)
    timer = Process.send_after(self(), :frame, interval)
    {:noreply, %{state | frame_timer: timer, interval_ms: interval}}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:frames, :visible, :last_draw_us, :last_build_us, :interval_ms]),
     state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.visible, do: hide(state)
    :ok
  end

  # ------------------------------------------------------------------ visibility

  defp show(state) do
    Logger.info("#{state.vt} is in the foreground: drawing")
    Mode.set(:visible, true)
    if state.kd_mode, do: kd(state, true)
    Render.invalidate(@backend)
    send(self(), :frame)
    %{state | visible: true}
  end

  defp hide(state) do
    Logger.info("#{state.vt} is in the background: not drawing")
    Mode.set(:visible, false)
    if state.frame_timer, do: Process.cancel_timer(state.frame_timer)
    if state.kd_mode, do: kd(state, false)
    %{state | visible: false, frame_timer: nil}
  end

  defp kd(state, graphics?) do
    case Render.kd_mode(@backend, state.tty, graphics?) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("KDSETMODE: #{reason}")
    end
  end

  @doc "The name of the foreground VT (\"tty12\"), or nil."
  def foreground_vt(file) do
    case File.read(file) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> nil
    end
  end

  # ------------------------------------------------------------------ pacing

  @doc """
  Milliseconds until the next frame: the shortest interval among the sensors
  feeding the panels drawn, between 1000/max_fps and 1000 ms.
  """
  def frame_interval(sensor_names, state) do
    max_fps =
      if Mode.get().on_battery, do: min(state.max_fps, state.battery_max_fps), else: state.max_fps

    floor_ms = round(1000 / max_fps)

    fastest =
      SensorSupervisor.all()
      |> Enum.filter(&(Sensor.name_of(&1) in sensor_names and Process.whereis(&1) != nil))
      |> Enum.map(&Sensor.interval/1)
      |> Enum.min(fn -> 1000 end)

    fastest |> max(floor_ms) |> min(1000)
  end

  # ------------------------------------------------------------------ geometry

  defp geometry(path, nil) do
    if String.starts_with?(path, "/dev/fb") do
      Render.fb_geometry("/sys/class/graphics/" <> Path.basename(path))
    else
      raise ArgumentError, "#{path} is not a framebuffer device: give :size for a stand-in file"
    end
  end

  # A stand-in file: XRGB8888 rows with no padding; created at the right size.
  defp geometry(path, {w, h}) do
    stride = w * 4
    size = stride * h

    case File.stat(path) do
      {:ok, %{size: ^size}} -> :ok
      _ -> File.write!(path, :binary.copy(<<0>>, size))
    end

    %{width: w, height: h, stride: stride}
  end
end
