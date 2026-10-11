defmodule Jantar.Sensors.Swap do
  @moduledoc """
  Swap: how much is in use (/proc/meminfo), and how fast pages move in and
  out (pswpin and pswpout in /proc/vmstat). The rates matter more than the
  size: steady swapping is the machine actually short of memory.

  Series `{:swap, :in}` and `{:swap, :out}` (pages/s, 30 min). Unavailable
  without swap.
  """
  @behaviour Jantar.Sensor
  alias Jantar.{Core, Sysfs}

  @impl true
  def defaults, do: [interval: 1_000]

  @impl true
  def init(opts) do
    root = opts[:root]

    case Core.meminfo(Sysfs.read(root, "/proc/meminfo") || "") do
      %{swap_total_kb: total} when total > 0 ->
        {:ok, %{root: root, prev: nil},
         [{{:swap, :in}, 30 * 60_000}, {{:swap, :out}, 30 * 60_000}]}

      _ ->
        {:unavailable, :no_swap}
    end
  end

  @impl true
  def sample(state, now) do
    {pin, pout} = :jantar_core@parse.swap_pages(Sysfs.read_raw(state.root, "/proc/vmstat") || "")
    mem = Core.meminfo(Sysfs.read(state.root, "/proc/meminfo") || "")

    {rin, rout} =
      case state.prev do
        {i0, o0, t0} ->
          {Core.ok_or_nil(:jantar_core@rate.per_second(i0, pin, now - t0)),
           Core.ok_or_nil(:jantar_core@rate.per_second(o0, pout, now - t0))}

        nil ->
          {nil, nil}
      end

    readings = if rin, do: [{{:swap, :in}, rin}, {{:swap, :out}, rout}], else: []

    current = %{
      in: rin,
      out: rout,
      used_kb: (mem && mem.swap_used_kb) || 0,
      total_kb: (mem && mem.swap_total_kb) || 0
    }

    {:ok, readings, current, %{state | prev: {pin, pout, now}}}
  end
end
