defmodule Jantar.Format do
  @moduledoc """
  hud's text formatting (its `pct`, `fmt_rate`, `fmt_bytes`, ...), so
  `mix jantar.dump` reads the same as `hud --once` and the two can be compared.
  `nil` formats as "…" (hud's "not measured yet").
  """

  def pct(nil), do: "…"
  def pct(v), do: "#{round(v * 100)}%"

  def temp(nil), do: ""
  def temp(c), do: "#{round(c)}°C"

  @doc "Bytes per second: 512B, 12K, 3.4M."
  def rate(nil), do: "…"
  def rate(b) when b >= 1_048_576, do: "#{float1(b / 1_048_576)}M"
  def rate(b) when b >= 1024, do: "#{round(b / 1024)}K"
  def rate(b), do: "#{round(b)}B"

  @doc "A count in SI units: 512, 7.3K, 12M, 3.1G (one decimal below 10 units)."
  def count(nil), do: "…"

  def count(n) do
    case Enum.find([{"G", 1.0e9}, {"M", 1.0e6}, {"K", 1.0e3}], fn {_, u} -> n >= u end) do
      {unit, u} when n < 10 * u -> float1(n / u) <> unit
      {unit, u} -> "#{round(n / u)}#{unit}"
      nil -> "#{round(n)}"
    end
  end

  import Bitwise, only: [<<<: 2]
  @units [{"T", 1 <<< 40}, {"G", 1 <<< 30}, {"M", 1 <<< 20}, {"K", 1 <<< 10}]

  @doc "A byte count: 1.5G, 62G, 812M (one decimal below 10 units)."
  def bytes(nil), do: "…"

  def bytes(b) do
    case Enum.find(@units, fn {_, n} -> b >= n end) do
      {unit, n} when b < 10 * n -> float1(b / n) <> unit
      {unit, n} -> "#{round(b / n)}#{unit}"
      nil -> "#{trunc(b)}B"
    end
  end

  def kb(kb), do: bytes(kb * 1024)

  @doc "Minutes as h:mm, e.g. 2h05."
  def mins(m) do
    m = round(m)
    "#{div(m, 60)}h#{String.pad_leading("#{rem(m, 60)}", 2, "0")}"
  end

  @doc "An age in seconds: 42s, 7m, 1h30."
  def age(s) when s < 60, do: "#{trunc(s)}s"
  def age(s) when s < 3600, do: "#{trunc(s / 60)}m"
  def age(s), do: mins(s / 60)

  def signed_watts(w) do
    w = round(w)

    cond do
      w > 0 -> "+#{w} W"
      w < 0 -> "−#{-w} W"
      true -> "0 W"
    end
  end

  @doc "A wifi band from a frequency in MHz."
  def band(f) when f < 3000, do: "2.4"
  def band(f) when f < 5925, do: "5"
  def band(_), do: "6"

  @doc "A window or interval in ms: 250ms, 2s, 5m."
  def duration(ms) when ms < 1000, do: "#{ms}ms"
  def duration(ms) when ms < 60_000, do: "#{float_trim(ms / 1000)}s"
  def duration(ms), do: "#{float_trim(ms / 60_000)}m"

  # Like Python's "%.1f".
  defp float1(x), do: :erlang.float_to_binary(x / 1, decimals: 1)

  defp float_trim(x) do
    if x == trunc(x), do: "#{trunc(x)}", else: float1(x)
  end
end
