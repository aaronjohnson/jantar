defmodule Jantar.Sensors.Disk do
  @moduledoc """
  Storage: the system disk's read and write rates from /proc/diskstats,
  its temperature (the nvme hwmon), and which cgroup is writing most, from
  each cgroup's io.stat. The kernel counts I/O per device and per cgroup,
  not per btrfs subvolume, so "who" means a service or the user session:
  nix-daemon building, the CI runner, a browser.

  Series `{:disk, :read}` and `{:disk, :write}` (bytes/s, 5 min). The top
  writer is worked out every 10 s, over those 10 s.
  """
  @behaviour Jantar.Sensor
  alias Jantar.{Core, Sysfs}

  @top_every_ms 10_000

  @impl true
  def defaults, do: [interval: 1_000]

  @impl true
  def init(opts) do
    root = opts[:root]

    case find_disk(root) do
      nil ->
        {:unavailable, :no_disk}

      {name, devno} ->
        state = %{
          root: root,
          name: name,
          devno: devno,
          temp: find_temp(root),
          prev: nil,
          top: nil,
          cgroups: nil,
          cgroups_t: nil
        }

        {:ok, state, [{{:disk, :read}, 5 * 60_000}, {{:disk, :write}, 5 * 60_000}]}
    end
  end

  @impl true
  def sample(state, now) do
    case :jantar_core@parse.diskstats(
           Sysfs.read_raw(state.root, "/proc/diskstats") || "",
           state.name
         ) do
      {:ok, {read_total, write_total}} ->
        {read, write} =
          case state.prev do
            {r0, w0, t0} ->
              {Core.ok_or_nil(:jantar_core@rate.per_second(r0, read_total, now - t0)),
               Core.ok_or_nil(:jantar_core@rate.per_second(w0, write_total, now - t0))}

            nil ->
              {nil, nil}
          end

        state = %{state | prev: {read_total, write_total, now}} |> top_writer(now)
        temp = state.temp && Sysfs.number(state.root, state.temp)

        readings = if read, do: [{{:disk, :read}, read}, {{:disk, :write}, write}], else: []

        current = %{
          device: state.name,
          read: read,
          write: write,
          temp_c: temp && temp / 1000,
          top: state.top
        }

        {:ok, readings, current, state}

      {:error, _} ->
        {:unavailable, :disk_gone, state}
    end
  end

  # Every 10 s: each cgroup's bytes written since last time; the largest
  # (by bytes/s) is the top writer, or nil when nothing wrote.
  defp top_writer(%{cgroups_t: t0} = state, now) when is_integer(t0) and now - t0 < @top_every_ms,
    do: state

  defp top_writer(state, now) do
    totals = cgroup_writes(state.root, state.devno)

    top =
      with prev when is_map(prev) <- state.cgroups,
           dt when dt > 0 <- now - state.cgroups_t do
        totals
        |> Enum.map(fn {name, w} -> {name, (w - Map.get(prev, name, w)) * 1000 / dt} end)
        |> Enum.filter(fn {_, rate} -> rate > 0 end)
        |> Enum.max_by(&elem(&1, 1), fn -> nil end)
      else
        _ -> state.top
      end

    %{state | cgroups: totals, cgroups_t: now, top: top}
  end

  # Bytes written per cgroup: each system service, the user session.
  defp cgroup_writes(root, devno) do
    services = Sysfs.wildcard(root, "/sys/fs/cgroup/system.slice/*.service")
    users = Sysfs.wildcard(root, "/sys/fs/cgroup/user.slice/user-*.slice")

    for dir <- services ++ users,
        text = Sysfs.read_raw(root, dir <> "/io.stat"),
        text != nil,
        into: %{} do
      {_read, written} = :jantar_core@parse.cgroup_io(text, devno)
      {dir |> Path.basename() |> String.replace_suffix(".service", ""), written}
    end
  end

  @doc "The system disk: the first NVMe namespace, else the first sd disk; `{name, \"maj:min\"}`."
  def find_disk(root) do
    candidates =
      Sysfs.wildcard(root, "/sys/block/nvme*n1") ++ Sysfs.wildcard(root, "/sys/block/sd?")

    Enum.find_value(candidates, fn dir ->
      case Sysfs.read(root, dir <> "/dev") do
        nil -> nil
        devno -> {Path.basename(dir), devno}
      end
    end)
  end

  defp find_temp(root) do
    Enum.find_value(Sysfs.wildcard(root, "/sys/class/hwmon/hwmon*"), fn dir ->
      if Sysfs.read(root, dir <> "/name") == "nvme" and Sysfs.read(root, dir <> "/temp1_input"),
        do: dir <> "/temp1_input"
    end)
  end
end
