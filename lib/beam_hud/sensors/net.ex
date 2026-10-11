defmodule BeamHud.Sensors.Net do
  @moduledoc """
  Network throughput from /proc/net/dev: bytes per second received and sent,
  summed over every interface except lo (hud's read_net). Series `:rx` and
  `:tx` (bytes/s, 5 min); the first sample has no rate.
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.{Core, Sysfs}

  @impl true
  def defaults, do: [interval: 250]

  @impl true
  def init(opts) do
    if Sysfs.exists?(opts[:root], "/proc/net/dev") do
      {:ok, %{root: opts[:root], prev: nil}, [rx: 5 * 60_000, tx: 5 * 60_000]}
    else
      {:unavailable, :no_proc_net_dev}
    end
  end

  @impl true
  def sample(state, now) do
    case Sysfs.read(state.root, "/proc/net/dev") do
      nil ->
        {:unavailable, :no_proc_net_dev, state}

      text ->
        {rx_total, tx_total} = Core.net_totals(text)

        {rx, tx} =
          case state.prev do
            {rx0, tx0, t0} ->
              {Core.ok_or_nil(:hud_core@rate.per_second(rx0, rx_total, now - t0)),
               Core.ok_or_nil(:hud_core@rate.per_second(tx0, tx_total, now - t0))}

            nil ->
              {nil, nil}
          end

        readings = if rx, do: [rx: rx, tx: tx], else: []
        current = %{rx: rx, tx: tx, rx_total: rx_total, tx_total: tx_total}
        {:ok, readings, current, %{state | prev: {rx_total, tx_total, now}}}
    end
  end
end
