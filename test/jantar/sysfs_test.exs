defmodule Jantar.SysfsTest do
  use ExUnit.Case, async: true

  import Jantar.Fixtures
  alias Jantar.Sysfs

  @moduletag :tmp_dir

  test "reads under the root, quietly", %{tmp_dir: dir} do
    write_tree(dir, %{"/sys/a/value" => " 42\n", "/sys/a/text" => "Charging\n"})
    assert Sysfs.read(dir, "/sys/a/text") == "Charging"
    assert Sysfs.number(dir, "/sys/a/value") == 42.0
    assert Sysfs.number(dir, "/sys/a/text") == nil
    assert Sysfs.read(dir, "/sys/missing") == nil
    assert Sysfs.wildcard(dir, "/sys/a/*") == ["/sys/a/text", "/sys/a/value"]
  end

  test "realpath follows relative links through linked directories", %{tmp_dir: dir} do
    # Like sysfs: /sys/class/drm/card0 -> ../../devices/pci/drm/card0, and
    # card0/device -> ../../../pci, relative to where card0 really is.
    File.mkdir_p!(Path.join(dir, "sys/devices/pci/drm/card0"))
    File.mkdir_p!(Path.join(dir, "sys/class/drm"))
    File.ln_s!("../../devices/pci/drm/card0", Path.join(dir, "sys/class/drm/card0"))
    File.ln_s!("../..", Path.join(dir, "sys/devices/pci/drm/card0/device"))

    assert Sysfs.realpath(dir, "/sys/class/drm/card0") == "/sys/devices/pci/drm/card0"
    assert Sysfs.realpath(dir, "/sys/class/drm/card0/device") == "/sys/devices/pci"
    # Not a link: unchanged.
    assert Sysfs.realpath(dir, "/sys/devices/pci") == "/sys/devices/pci"
  end

  test "realpath stops on a link loop", %{tmp_dir: dir} do
    File.ln_s!("loop", Path.join(dir, "loop"))
    assert is_binary(Sysfs.realpath(dir, "/loop"))
  end
end
