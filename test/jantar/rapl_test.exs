defmodule Jantar.RaplTest do
  @moduledoc "RAPL power from a stand-in counter tree, and the energy file it publishes."
  use ExUnit.Case, async: true

  import Jantar.Fixtures
  alias Jantar.Sensors.Rapl

  @moduletag :tmp_dir
  @dir "/sys/class/powercap/intel-rapl:0"

  defp counters(dir, pkg_uj, core_uj) do
    write_tree(dir, %{
      (@dir <> "/name") => "package-0\n",
      (@dir <> "/energy_uj") => "#{pkg_uj}\n",
      (@dir <> "/max_energy_range_uj") => "262143328850\n",
      # sysfs lists the sub-domains beside the package, too.
      (@dir <> ":0/name") => "core\n",
      (@dir <> ":0/energy_uj") => "#{core_uj}\n",
      (@dir <> ":0/max_energy_range_uj") => "262143328850\n"
    })
  end

  test "watts from counter differences, and the counters published", %{tmp_dir: dir} do
    file = Path.join(dir, "energy.json")
    counters(dir, 1_000_000, 400_000)
    {:ok, state, _series} = Rapl.init(Jantar.Sensor.options(Rapl, root: dir, publish: file))
    {:ok, [], _, state} = Rapl.sample(state, 0)

    counters(dir, 6_000_000, 1_400_000)
    {:ok, series, watts, _} = Rapl.sample(state, 1000)
    assert watts[:package] == 5.0 and watts[:cores] == 1.0
    assert {:rapl, :package} in Enum.map(series, &elem(&1, 0))

    published = file |> File.read!() |> JSON.decode!()
    assert published["uj"] == %{"package" => 6_000_000, "cores" => 1_400_000}
    assert published["max_uj"]["package"] == 262_143_328_850
    assert is_integer(published["t_ms"])
    # Readable by anyone (the experiments run as the user), and no leftover.
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o644
    refute File.exists?(file <> ".new")
  end

  test "nothing published without a path", %{tmp_dir: dir} do
    counters(dir, 1, 1)
    {:ok, state, _} = Rapl.init(Jantar.Sensor.options(Rapl, root: dir, publish: nil))
    {:ok, _, _, _} = Rapl.sample(state, 0)
    assert Path.wildcard(Path.join(dir, "*.json")) == []
  end
end
