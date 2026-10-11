defmodule BeamHud.Sensors.Gpu do
  @moduledoc """
  GPU utilisation per GT (Intel xe: tile0/gt0 render, gt1 media) from each
  GT's cumulative idle residency, and its current clock (hud's discover and
  read_gpu). Series `{:gpu, name}` per GT, e.g. `{:gpu, "gt0-rc"}` (0..1,
  5 min).
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.{Core, Sysfs}

  @impl true
  def defaults, do: [interval: 250]

  @impl true
  def init(opts) do
    root = opts[:root]
    {gts, driver} = discover(root)

    if gts == [] do
      {:unavailable, :no_gpu_gts}
    else
      gts =
        for dir <- gts do
          %{
            dir: dir,
            name: Sysfs.read(root, dir <> "/gtidle/name") || Path.basename(dir),
            max_mhz: Sysfs.number(root, dir <> "/freq0/max_freq") || 0.0,
            prev: nil
          }
        end

      series = for gt <- gts, do: {{:gpu, gt.name}, 5 * 60_000}
      {:ok, %{root: root, driver: driver, gts: gts}, series}
    end
  end

  @impl true
  def sample(state, now) do
    gts =
      for gt <- state.gts do
        idle = Sysfs.number(state.root, gt.dir <> "/gtidle/idle_residency_ms")
        mhz = trunc(Sysfs.number(state.root, gt.dir <> "/freq0/act_freq") || 0)

        busy =
          case {gt.prev, idle} do
            {{idle0, t0}, idle} when idle != nil ->
              Core.ok_or_nil(:hud_core@rate.busy_from_idle(idle0, idle, now - t0))

            _ ->
              nil
          end

        Map.merge(gt, %{busy: busy, mhz: mhz, prev: idle && {idle, now}})
      end

    readings = for gt <- gts, gt.busy != nil, do: {{:gpu, gt.name}, gt.busy}

    current = %{
      driver: state.driver,
      gts: Enum.map(gts, &Map.take(&1, [:name, :busy, :mhz, :max_mhz]))
    }

    {:ok, readings, current, %{state | gts: gts}}
  end

  @doc """
  The GT directories with idle counters, over every DRM card (a device with
  several card nodes counted once), and the first card's driver name.
  """
  def discover(root) do
    devices =
      Sysfs.wildcard(root, "/sys/class/drm/card[0-9]")
      |> Enum.map(&Sysfs.realpath(root, &1 <> "/device"))
      |> Enum.uniq()

    driver =
      case devices do
        [dev | _] -> Path.basename(Sysfs.realpath(root, dev <> "/driver"))
        [] -> ""
      end

    gts =
      for dev <- devices,
          gt <- Sysfs.wildcard(root, dev <> "/tile*/gt*"),
          Sysfs.exists?(root, gt <> "/gtidle/idle_residency_ms"),
          do: gt

    {gts, driver}
  end
end
