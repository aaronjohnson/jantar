defmodule Jantar.FormatTest do
  @moduledoc "The same strings hud prints for the same numbers."
  use ExUnit.Case, async: true

  alias Jantar.Format

  test "percentages, temperatures and rates" do
    assert Format.pct(0.0852) == "9%"
    assert Format.pct(nil) == "…"
    assert Format.temp(86.0) == "86°C"
    assert Format.rate(193.4) == "193B"
    assert Format.rate(2409.9) == "2K"
    assert Format.rate(3_500_000) == "3.3M"
  end

  test "byte counts" do
    assert Format.bytes(2_808_987_602) == "2.6G"
    assert Format.bytes(762_615_367) == "727M"
    assert Format.kb(65_309_752) == "62G"
    assert Format.bytes(0) == "0B"
  end

  test "times and watts" do
    assert Format.mins(125) == "2h05"
    assert Format.age(42) == "42s"
    assert Format.age(600) == "10m"
    assert Format.age(5400) == "1h30"
    assert Format.signed_watts(23.1) == "+23 W"
    assert Format.signed_watts(-23.1) == "−23 W"
    assert Format.signed_watts(0.2) == "0 W"
    assert Format.duration(250) == "250ms"
    assert Format.duration(2000) == "2s"
    assert Format.duration(1_800_000) == "30m"
  end

  test "wifi bands" do
    assert Enum.map([2412, 5180, 6375], &Format.band/1) == ["2.4", "5", "6"]
  end
end
