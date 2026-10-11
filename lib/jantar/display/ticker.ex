defmodule Jantar.Display.Ticker do
  @moduledoc """
  Draws frames while the dashboard's VT is the one on screen, and nothing
  otherwise.

    * Every 500 ms it reads which VT is in the foreground
      (/sys/class/tty/tty0/active, e.g. "tty12"): one small file read.
    * On becoming visible: `Jantar.Mode` visible, KD_GRAPHICS on the tty (so
      the console stops drawing text over us), and a full redraw: whatever
      was on screen before is unknown.
    * While visible: a frame (snapshot History, build the display list, draw)
      at the pace of the fastest sensor behind the panels on screen: 4 fps
      while the 250 ms CPU dial is up, 1 fps if only slow series were. Capped
      by `:max_fps`, and by `:battery_max_fps` on battery.
    * On becoming hidden, or on shutdown: KD_TEXT, Mode not visible. The
      sensors keep collecting either way.

  Keys on the dashboard's VT (`keys/2`): in the overview, 1 / 2 / 3 show
  live samples, the last day or the last 30 days. A section's letter
  (c CPU, g GPU · NPU, m memory and storage, t thermals, p power,
  n network) zooms in on it, full screen, where 1 / 2 / 3 show the last
  1, 5 or 30 minutes. Esc, 0, q or the same letter again go back to the
  overview, as it was.

  With a real tty (KD_GRAPHICS), the VT is first put in process mode
  (VT_SETMODE). The kernel ignores switches away from a KD_GRAPHICS VT in
  automatic mode, so without it Ctrl+Alt+F1 would do nothing. In process
  mode the kernel sends SIGUSR2 (`Jantar.Display.VtSignal`) when someone
  switches away, waits for VT_RELDISP, and sends it again after switching
  back. If process mode can't be set, KD_GRAPHICS isn't used at all.
  """
  use GenServer
  require Logger

  alias Jantar.{Frame, Mode, Render, Sensor, SensorSupervisor}

  @poll_ms 500
  @backend Jantar.Display.Backend

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Counters for tests and `mix jantar.fb`: frames drawn, last draw time, visibility."
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    # So terminate/2 runs on shutdown and can give the console back.
    Process.flag(:trap_exit, true)

    fb_path = Keyword.get(opts, :fb, "/dev/fb0")
    tty = Keyword.get(opts, :tty, "/dev/tty12")

    state = %{
      fb_path: fb_path,
      size: opts[:size],
      fb_open: false,
      fb_error: nil,
      fb_failures: 0,
      tty: tty,
      vt: Path.basename(tty),
      active_file: Keyword.get(opts, :active_file, "/sys/class/tty/tty0/active"),
      kd_mode: Keyword.get(opts, :kd_mode, String.starts_with?(fb_path, "/dev/")),
      frame_error: nil,
      width: nil,
      height: nil,
      label: Keyword.get(opts, :label, Atom.to_string(Keyword.get(opts, :backend, :rust))),
      max_fps: Keyword.get(opts, :max_fps, 4),
      battery_max_fps: Keyword.get(opts, :battery_max_fps, 2),
      visible: false,
      vt_process: false,
      scale: :live,
      focus: nil,
      window: 300_000,
      keys: nil,
      held: false,
      frame_timer: nil,
      frames: 0,
      last_draw_us: nil,
      last_build_us: nil,
      interval_ms: nil
    }

    # Hidden until the poll finds our VT in front.
    Mode.set(:visible, false)
    send(self(), :open_fb)
    {:ok, state}
  end

  # Map the framebuffer. A failure (no permission, no device) is logged once
  # in plain words and retried with backoff, 5 s doubling to 1 min: fixing
  # group membership or the service config shouldn't need a restart, and a
  # missing permission shouldn't become a crash loop.
  @impl true
  def handle_info(:open_fb, state) do
    case open_fb(state) do
      {:ok, geometry} ->
        if state.fb_error, do: Logger.info("#{state.fb_path}: opened after all")
        send(self(), :poll)
        state = if state.kd_mode and not state.vt_process, do: claim_vt(state), else: state

        {:noreply,
         %{state | fb_open: true, fb_error: nil, width: geometry.width, height: geometry.height}}

      {:error, reason} ->
        message = explain(state.fb_path, reason)
        if message != state.fb_error, do: Logger.error(message <> "; will keep retrying")
        retry = min(5_000 * Integer.pow(2, state.fb_failures), 60_000)
        Process.send_after(self(), :open_fb, retry)
        {:noreply, %{state | fb_error: message, fb_failures: min(state.fb_failures + 1, 4)}}
    end
  end

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

  # The kernel's signal for our VT in process mode. Releases and acquires
  # alternate, so whether we hold the VT says which this is.
  def handle_info(:vt_signal, %{vt_process: true, held: true} = state) do
    state = if state.visible, do: hide(state, false), else: state
    vt_reldisp(state, 1)
    {:noreply, %{state | held: false}}
  end

  def handle_info(:vt_signal, %{vt_process: true} = state) do
    vt_reldisp(state, 2)
    state = if state.visible, do: state, else: show(state)
    {:noreply, %{state | held: true}}
  end

  def handle_info(:vt_signal, state), do: {:noreply, state}

  # Keys typed on the dashboard's VT (see keys/2).
  def handle_info({port, {:data, bytes}}, %{keys: port} = state) do
    view = Map.take(state, [:scale, :focus, :window])
    new = keys(bytes, view)

    if new != view and state.visible do
      if state.frame_timer, do: Process.cancel_timer(state.frame_timer)
      Render.invalidate(@backend)
      send(self(), :frame)
    end

    {:noreply, Map.merge(state, new)}
  end

  def handle_info({port, {:exit_status, _}}, %{keys: port} = state),
    do: {:noreply, %{state | keys: nil}}

  def handle_info(:frame, %{visible: false} = state), do: {:noreply, %{state | frame_timer: nil}}

  def handle_info(:frame, state) do
    {build_us, {list, meta}} =
      :timer.tc(fn ->
        Frame.build(Frame.snapshot(System.monotonic_time(:millisecond), snapshot_scale(state)),
          width: state.width,
          height: state.height,
          label: label(state),
          focus: state.focus
        )
      end)

    state =
      case Render.fb(@backend, list) do
        {:ok, draw_us, _bands} ->
          %{
            state
            | frames: state.frames + 1,
              last_draw_us: draw_us,
              last_build_us: build_us,
              frame_error: nil
          }

        {:error, reason} ->
          # Once per distinct error, not every frame.
          if reason != state.frame_error, do: Logger.warning("frame not drawn: #{reason}")
          %{state | frame_error: reason}
      end

    # An archive changes once a minute: a frame every 2 s is plenty.
    interval =
      if snapshot_scale(state) in [:day, :month],
        do: 2000,
        else: frame_interval(meta.sensors, state)

    timer = Process.send_after(self(), :frame, interval)
    {:noreply, %{state | frame_timer: timer, interval_ms: interval}}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     Map.take(state, [:frames, :visible, :last_draw_us, :last_build_us, :interval_ms, :fb_error]),
     state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.visible, do: hide(state)

    # Back to text and automatic switching, even if we're not on screen:
    # the VT stays in KD_GRAPHICS while switched away.
    if state.vt_process do
      kd(state, false)
      Jantar.Render.Native.vt_process(state.tty, 0)
    end

    if state.keys do
      Jantar.Render.Native.tty_raw(state.tty, false)
      Port.close(state.keys)
    end

    :ok
  end

  # ------------------------------------------------------------------ visibility

  defp show(state) do
    Logger.info("#{state.vt} is in the foreground: drawing")
    Mode.set(:visible, true)

    if state.kd_mode do
      kd(state, true)
      restore_fb(state)
    end

    Render.invalidate(@backend)
    send(self(), :frame)
    %{state | visible: true}
  end

  # text?: false when releasing the VT in process mode: it stays in
  # KD_GRAPHICS while away, so it doesn't flash its text console on the way.
  defp hide(state, text? \\ true) do
    Logger.info("#{state.vt} is in the background: not drawing")
    Mode.set(:visible, false)
    if state.frame_timer, do: Process.cancel_timer(state.frame_timer)
    if state.kd_mode and text?, do: kd(state, false)
    %{state | visible: false, frame_timer: nil}
  end

  # KDSETMODE is done here, in the BEAM's own process, whatever the backend:
  # the kernel allows it on a process's controlling terminal, and under the
  # service the tty is the BEAM's. A Port runs in a session of its own
  # (erl_child_setup calls setsid), so the cairo program couldn't, without
  # CAP_SYS_TTY_CONFIG. The call is one ioctl in the Rust NIF.
  defp kd(state, graphics?) do
    case Jantar.Render.Native.kd_mode(state.tty, graphics?) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "#{reason} (KDSETMODE needs the tty as controlling terminal, or " <>
            "CAP_SYS_TTY_CONFIG); the console may draw over the dashboard"
        )
    end
  end

  # Process mode for our VT, with SIGUSR2 routed to us. Without it, KD_GRAPHICS
  # would make the VT impossible to switch away from, so on failure kd_mode is
  # turned off: the console may then draw over the dashboard, but never traps
  # anyone on it.
  defp claim_vt(state) do
    Jantar.Display.VtSignal.install()

    case Jantar.Render.Native.vt_process(state.tty, Jantar.Display.VtSignal.number()) do
      ok when ok in [:ok, {:ok, :ok}] ->
        state = %{state | vt_process: true, held: foreground_vt(state.active_file) == state.vt}
        listen_keys(state)

      {:error, reason} ->
        Logger.warning(
          "#{reason}: not switching #{state.vt} to graphics mode, since it couldn't " <>
            "then be switched away from; the console may draw over the dashboard"
        )

        %{state | kd_mode: false}
    end
  end

  # Coming straight from a compositor, the display still shows its last
  # frame: ask the driver to scan out the framebuffer again.
  defp restore_fb(state) do
    case Jantar.Render.Native.fb_restore(state.fb_path) do
      ok when ok in [:ok, {:ok, :ok}] -> :ok
      {:error, reason} -> Logger.warning("#{reason}; the screen may not show the dashboard")
    end
  end

  # Read keys from the VT: raw mode (each key at once, no echo), and `cat` of
  # the tty in a Port, which sends us each key as it comes and costs nothing
  # in between. A failure just means no keyboard.
  defp listen_keys(state) do
    with ok when ok in [:ok, {:ok, :ok}] <- Jantar.Render.Native.tty_raw(state.tty, true),
         cat when is_binary(cat) <- System.find_executable("cat") do
      port = Port.open({:spawn_executable, cat}, [:binary, :exit_status, args: [state.tty]])
      %{state | keys: port}
    else
      other ->
        Logger.warning("no keyboard on #{state.vt}: #{inspect(other)}")
        state
    end
  end

  # ------------------------------------------------------------------ keys

  @sections %{
    ?c => "CPU",
    ?g => "GPU · NPU",
    ?m => "MEMORY · STORAGE",
    ?t => "THERMALS",
    ?p => "POWER",
    ?n => "NETWORK"
  }
  @windows %{?1 => 60_000, ?2 => 300_000, ?3 => 1_800_000}
  @scales %{?1 => :live, ?2 => :day, ?3 => :month}

  @doc """
  What the keys typed (one read's bytes) do to the view, a map of `:scale`
  (overview: `:live`, `:day`, `:month`), `:focus` (nil, or the zoomed
  section's title) and `:window` (zoomed: ms shown). The overview's scale is
  kept while zoomed. A lone Esc goes back; Esc inside a longer read is the
  start of an arrow or function key's sequence, and is ignored.
  """
  def keys(<<27>>, view), do: %{view | focus: nil}
  def keys(bytes, view), do: bytes |> :binary.bin_to_list() |> Enum.reduce(view, &key/2)

  defp key(k, %{focus: nil} = view) do
    cond do
      section = @sections[k] -> %{view | focus: section, window: 300_000}
      scale = @scales[k] -> %{view | scale: scale}
      true -> view
    end
  end

  defp key(k, view) do
    cond do
      k in [?0, ?q] or @sections[k] == view.focus -> %{view | focus: nil}
      section = @sections[k] -> %{view | focus: section, window: 300_000}
      window = @windows[k] -> %{view | window: window}
      true -> view
    end
  end

  defp snapshot_scale(%{focus: nil, scale: scale}), do: scale
  defp snapshot_scale(%{window: ms}), do: {:window, ms}

  # Top right: the backend, the view, and the keys.
  defp label(%{keys: nil} = state), do: state.label

  defp label(%{focus: nil} = state) do
    scale = %{live: "live", day: "24 h", month: "30 days"}[state.scale]
    "#{state.label} · #{scale}   1 live  2 day  3 month   zoom c g m t p n"
  end

  defp label(state) do
    "#{state.label} · #{state.focus} #{div(state.window, 60_000)} min   " <>
      "1 1m  2 5m  3 30m   esc back"
  end

  defp vt_reldisp(state, arg) do
    case Jantar.Render.Native.vt_reldisp(state.tty, arg) do
      ok when ok in [:ok, {:ok, :ok}] -> :ok
      {:error, reason} -> Logger.warning("#{reason}")
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

  # ------------------------------------------------------------------ framebuffer

  defp open_fb(state) do
    geometry = geometry(state.fb_path, state.size)

    case Render.open_fb(@backend, state.fb_path, geometry.width, geometry.height, geometry.stride) do
      :ok -> {:ok, geometry}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "One plain line about why the framebuffer can't be used."
  def explain(path, reason) do
    reason = to_string(reason)

    cond do
      reason =~ ~r/permission denied|eacces/i ->
        "#{path}: permission denied. The user running jantar needs the video group " <>
          "(log in again after adding it), or the service needs DeviceAllow for it"

      reason =~ ~r/no such file|enoent/i ->
        "#{path}: no such device. Is there a framebuffer console (fbcon / simpledrm)?"

      true ->
        "#{path}: #{reason}"
    end
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
