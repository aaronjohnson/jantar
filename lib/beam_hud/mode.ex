defmodule BeamHud.Mode do
  @moduledoc """
  A small global state every sensor can read cheaply: whether the dashboard is
  visible and whether the machine is on battery.

  It lives in `:persistent_term`, which makes reads as cheap as reading a
  constant, at the price of expensive writes (every process is scanned for
  references to the old value). That suits a value that changes a few times
  a day; `set/2` skips writes that change nothing.

  The battery sensor sets `:on_battery`; the display (a later milestone) will
  set `:visible`. Sensors stretch their intervals by `interval_factor/0`.
  """

  @key {__MODULE__, :mode}
  @default %{visible: true, on_battery: false}

  @doc "Install the default mode (keeps an existing one)."
  def init do
    if :persistent_term.get(@key, nil) == nil, do: :persistent_term.put(@key, @default)
    :ok
  end

  @doc "The current mode, e.g. `%{visible: true, on_battery: false}`."
  def get, do: :persistent_term.get(@key, @default)

  @doc "Set one flag (`:visible` or `:on_battery`)."
  def set(flag, value) when flag in [:visible, :on_battery] and is_boolean(value) do
    mode = get()
    if Map.get(mode, flag) != value, do: :persistent_term.put(@key, %{mode | flag => value})
    :ok
  end

  @doc """
  How much to stretch sensor intervals now: the configured
  `:hidden_on_battery_factor` while hidden on battery, else 1.
  """
  def interval_factor(mode \\ get()) do
    if not mode.visible and mode.on_battery do
      Application.get_env(:beam_hud, :hidden_on_battery_factor, 1)
    else
      1
    end
  end
end
