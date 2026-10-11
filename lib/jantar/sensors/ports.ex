defmodule Jantar.Sensors.Ports do
  @moduledoc """
  What is in each USB-C port: nothing, a charger (with the power it is
  delivering, from the UCSI power supply for that port), the laptop powering
  a device, and which USB devices sit behind it.

  The kernel knows each USB-C port's power state (/sys/class/typec/portN),
  but on this firmware not which USB ports are behind which connector, so
  that mapping comes from calibration: `config :jantar, usb_bays: %{"3-3" =>
  "port1"}` (USB device path prefix => typec port), set by the NixOS module's
  `usbBays`. Removable devices that aren't mapped are listed as `other`.

  Bays are named for a Framework 13 (`config :jantar, bay_names:` to change).
  """
  @behaviour Jantar.Sensor
  alias Jantar.Sysfs

  @bay_names %{
    "port0" => "right back",
    "port1" => "right front",
    "port2" => "left front",
    "port3" => "left back"
  }

  @impl true
  def defaults, do: [interval: 5_000]

  @impl true
  def init(opts) do
    root = opts[:root]

    case Sysfs.wildcard(root, "/sys/class/typec/port[0-9]") do
      [] -> {:unavailable, :no_typec}
      ports -> {:ok, %{root: root, ports: Enum.map(ports, &Path.basename/1)}, []}
    end
  end

  @impl true
  def sample(state, _now) do
    root = state.root
    map = Application.get_env(:jantar, :usb_bays, %{})
    names = Map.merge(@bay_names, Application.get_env(:jantar, :bay_names, %{}))
    devices = usb_devices(root)

    ports =
      for p <- state.ports do
        partner? = Sysfs.exists?(root, "/sys/class/typec/#{p}-partner")
        role = role(Sysfs.read(root, "/sys/class/typec/#{p}/power_role"))

        %{
          port: p,
          bay: names[p] || p,
          partner: partner?,
          role: role,
          charger: if(partner? and role == :sink, do: charger(root, p)),
          devices: for({path, name} <- devices, mapped(map, path) == p, do: name)
        }
      end

    other = for {path, name} <- devices, mapped(map, path) == nil, do: name
    {:ok, [], %{ports: ports, other: other}, state}
  end

  # "source [sink]" -> :sink
  defp role(nil), do: nil

  defp role(text) do
    case Regex.run(~r/\[(\w+)\]/, text) do
      [_, r] -> String.to_atom(r)
      _ -> nil
    end
  end

  # The UCSI power supply for typec portN is ucsi-source-psy-USBC000:00(N+1).
  defp charger(root, "port" <> n) do
    dir = "/sys/class/power_supply/ucsi-source-psy-USBC000:00#{String.to_integer(n) + 1}"

    with "1" <- Sysfs.read(root, dir <> "/online"),
         uv when is_float(uv) <- Sysfs.number(root, dir <> "/voltage_now"),
         ua when is_float(ua) <- Sysfs.number(root, dir <> "/current_max") do
      %{volts: uv / 1.0e6, amps: ua / 1.0e6, watts: uv * ua / 1.0e12}
    else
      _ -> %{}
    end
  end

  # Removable USB devices, `{path, name}`: "3-3" => "FS ePass FIDO".
  defp usb_devices(root) do
    for dir <- Sysfs.wildcard(root, "/sys/bus/usb/devices/[0-9]*-[0-9]*"),
        not String.contains?(Path.basename(dir), ":"),
        Sysfs.read(root, dir <> "/removable") == "removable",
        product = Sysfs.read(root, dir <> "/product") do
      {Path.basename(dir), product}
    end
  end

  # The typec port a device path ("3-3" or "3-3.1" behind a hub) is mapped to.
  defp mapped(map, path) do
    Enum.find_value(map, fn {prefix, port} ->
      if path == prefix or String.starts_with?(path, prefix <> "."), do: port
    end)
  end
end
