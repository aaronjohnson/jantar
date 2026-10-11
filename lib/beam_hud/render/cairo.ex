defmodule BeamHud.Render.Cairo do
  @moduledoc """
  The cairo backend: a GenServer that owns a Port running the C program
  `cairo_port` (c/cairo_port), a separate OS process.

  Requests and replies are binaries framed with a 4-byte length
  (`{:packet, 4}`); the protocol is described at the top of cairo_port.c.
  The display list is passed through unchanged.

  The GenServer is linked to the port: if the C program dies (say, a
  segfault), the port closes, this process exits with `{:port_exited, status}`,
  and its supervisor starts a fresh one. Nothing else in the VM is affected;
  compare `BeamHud.Render.Rust`, where native code runs inside the VM.

  Option `allow_crash: true` lets `crash/1` make the program dereference
  NULL, to demonstrate exactly that.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc "Ask the C program to segfault (needs `allow_crash: true`)."
  def crash(server), do: GenServer.cast(server, :crash)

  @doc "Send any bytes and get them back: a protocol round trip."
  def echo(server, bytes), do: GenServer.call(server, {:echo, bytes})

  @doc "The OS pid of the C program."
  def os_pid(server), do: GenServer.call(server, :os_pid)

  @impl true
  def init(opts) do
    exe = Path.join(:code.priv_dir(:beam_hud), "cairo_port")
    args = if opts[:allow_crash], do: ["--allow-crash"], else: []
    port = Port.open({:spawn_executable, exe}, [:binary, {:packet, 4}, :exit_status, args: args])
    {regular, bold} = BeamHud.Render.fonts()

    case request(port, <<1, str16(regular)::binary, str16(bold)::binary>>) do
      {:ok, ""} -> {:ok, %{port: port}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:png, list, path}, _from, s) do
    {:reply,
     with({:ok, <<us::64-little>>} <- request(s.port, [2, str16(path), list]), do: {:ok, us}), s}
  end

  def handle_call({:open_fb, path, w, h, stride}, _from, s) do
    direct = if Application.get_env(:beam_hud, :cairo_direct, false), do: 1, else: 0
    msg = [3, <<w::32-little, h::32-little, stride::32-little, direct>>, path]
    {:reply, with({:ok, ""} <- request(s.port, msg), do: :ok), s}
  end

  def handle_call({:fb, list}, _from, s) do
    reply =
      with {:ok, <<us::64-little, bands::32-little>>} <- request(s.port, [4, list]),
           do: {:ok, us, bands}

    {:reply, reply, s}
  end

  def handle_call(:invalidate, _from, s),
    do: {:reply, with({:ok, ""} <- request(s.port, <<5>>), do: :ok), s}

  def handle_call({:kd_mode, tty, graphics?}, _from, s) do
    msg = [6, if(graphics?, do: 1, else: 0), tty]
    {:reply, with({:ok, ""} <- request(s.port, msg), do: :ok), s}
  end

  def handle_call({:echo, bytes}, _from, s), do: {:reply, request(s.port, [7, bytes]), s}
  def handle_call(:os_pid, _from, s), do: {:reply, Port.info(s.port, :os_pid) |> elem(1), s}

  @impl true
  def handle_cast(:crash, s) do
    Port.command(s.port, <<8>>)
    {:noreply, s}
  end

  # The C program exited (or crashed): stop, so the supervisor restarts us
  # with a fresh port.
  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    Logger.warning("cairo_port exited with status #{status}; restarting")
    {:stop, {:port_exited, status}, s}
  end

  # One request, one reply. Synchronous: the port answers in order.
  defp request(port, msg) do
    Port.command(port, msg)

    receive do
      {^port, {:data, <<0, rest::binary>>}} -> {:ok, rest}
      {^port, {:data, <<1, reason::binary>>}} -> {:error, reason}
      {^port, {:exit_status, status}} -> exit({:port_exited, status})
    after
      30_000 -> exit(:port_timeout)
    end
  end

  defp str16(s), do: <<byte_size(s)::16-little, s::binary>>
end
