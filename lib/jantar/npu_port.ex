defmodule Jantar.NpuPort do
  @moduledoc """
  The NPU's hardware counters from Level Zero, through the C program
  `npu_port` (c/npu_port) run as a Port. The protocol is described at the
  top of npu_port.c.

  Plain functions, not a process: the Port belongs to whoever calls
  `start/1` (the `Jantar.Sensors.NpuCounters` sensor), and every request is
  synchronous. If the program dies, the next request returns an error.

  Any Level Zero call wakes a suspended NPU, so `open/2` is only for while
  it is already awake; `close/1` lets it sleep again.
  """

  @timeout 5_000

  @doc "Where the release keeps the program."
  def exe, do: Path.join(:code.priv_dir(:jantar), "npu_port")

  @doc """
  Start the program. `:driver_path` is where the loader finds the NPU driver
  (libze_intel_npu); on NixOS that is /run/opengl-driver/lib.
  """
  def start(opts) do
    path =
      Enum.join(
        Enum.reject([opts[:driver_path], System.get_env("LD_LIBRARY_PATH")], &(&1 in [nil, ""])),
        ":"
      )

    env = [{~c"ZET_ENABLE_METRICS", ~c"1"}, {~c"LD_LIBRARY_PATH", String.to_charlist(path)}]

    Port.open({:spawn_executable, opts[:exe] || exe()}, [
      :binary,
      {:packet, 4},
      :exit_status,
      env: env
    ])
  end

  @doc "Stop the program."
  def stop(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Open streamers on these metric groups ("NOC", "FREQ", ...). Returns each
  group's name and metric names, in the order `read/2` reports them.
  """
  def open(port, groups) do
    with {:ok, <<n::16-little, rest::binary>>} <- request(port, [1, Enum.join(groups, ",")]) do
      {:ok, layout(n, rest)}
    end
  end

  @doc """
  What the streamers have collected since the last read: per group,
  `{name, reports, %{metric => value}}` with the newest report's values
  (an empty map when no report came).
  """
  def read(port, layout) do
    with {:ok, bin} <- request(port, <<2>>), do: {:ok, values(layout, bin)}
  end

  @doc "Close the streamers and the context, so the NPU can suspend."
  def close(port), do: with({:ok, ""} <- request(port, <<3>>), do: :ok)

  @doc "A protocol round trip: the same bytes back."
  def echo(port, bytes), do: request(port, [4, bytes])

  defp layout(0, _), do: []

  defp layout(n, <<len::16-little, name::binary-size(len), m::16-little, rest::binary>>) do
    {metrics, rest} = names(m, rest, [])
    [{name, metrics} | layout(n - 1, rest)]
  end

  defp names(0, rest, acc), do: {Enum.reverse(acc), rest}

  defp names(m, <<len::16-little, name::binary-size(len), rest::binary>>, acc),
    do: names(m - 1, rest, [name | acc])

  defp values([], _), do: []

  defp values([{name, metrics} | more], <<reports::32-little, rest::binary>>) do
    size = 8 * length(metrics)
    <<vals::binary-size(size), rest::binary>> = rest
    nums = for <<v::float-64-little <- vals>>, do: v
    current = if reports > 0, do: Map.new(Enum.zip(metrics, nums)), else: %{}
    [{name, reports, current} | values(more, rest)]
  end

  defp request(port, msg) do
    Port.command(port, msg)

    receive do
      {^port, {:data, <<0, rest::binary>>}} -> {:ok, rest}
      {^port, {:data, <<1, reason::binary>>}} -> {:error, reason}
      {^port, {:exit_status, status}} -> {:error, {:exited, status}}
    after
      @timeout -> {:error, :timeout}
    end
  rescue
    # The program has gone and the port with it.
    ArgumentError -> {:error, :closed}
  end
end
