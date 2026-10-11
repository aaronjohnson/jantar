defmodule Jantar.ModeTest do
  # Mode is global state: not async.
  use ExUnit.Case, async: false

  alias Jantar.Mode

  setup do
    on_exit(fn ->
      Mode.set(:visible, true)
      Mode.set(:on_battery, false)
      Application.put_env(:jantar, :hidden_on_battery_factor, 1)
    end)
  end

  test "defaults to visible, on mains" do
    assert Mode.get() == %{visible: true, on_battery: false}
  end

  test "sensors slow down only when hidden *and* on battery" do
    Application.put_env(:jantar, :hidden_on_battery_factor, 4)
    assert Mode.interval_factor() == 1

    Mode.set(:visible, false)
    assert Mode.interval_factor() == 1

    Mode.set(:on_battery, true)
    assert Mode.get() == %{visible: false, on_battery: true}
    assert Mode.interval_factor() == 4

    Mode.set(:visible, true)
    assert Mode.interval_factor() == 1
  end

  test "rejects unknown flags" do
    assert_raise FunctionClauseError, fn -> Mode.set(:loud, true) end
  end
end
