defmodule BeamHud.Core do
  @moduledoc """
  The boundary with the Gleam core (gleam/hud_core). Gleam modules compile to
  Erlang modules named `:hud_core@parse`, `:hud_core@rate`, ..., and Gleam
  values have plain Erlang shapes:

      Gleam                          Erlang / Elixir
      Ok(x) / Error(Nil)             {:ok, x} / {:error, nil}
      Some(x) / None                 {:some, x} / :none
      MemInfo(total: 1, ...)         {:mem_info, 1, ...}   (a tagged tuple)
      #(a, b)                        {a, b}
      True / False, Int, Float       true / false, integers, floats
      String                         binary (an Elixir string)

  Sensors call the Gleam functions directly where the result is already
  natural in Elixir; this module converts the records they get back into
  maps, so the rest of the app never matches on tuple positions.
  """

  @doc "A Gleam Option as a value or nil."
  def option({:some, x}), do: x
  def option(:none), do: nil

  @doc "A Gleam Result as a value or nil."
  def ok_or_nil({:ok, x}), do: x
  def ok_or_nil({:error, _}), do: nil

  @doc "A number from sysfs text (\"42\", \"5180.0\") as a float, or nil."
  def number(nil), do: nil
  def number(text), do: ok_or_nil(:hud_core@parse.number(text))

  @doc "/proc/meminfo as a map of kB values, or nil."
  def meminfo(text) do
    case :hud_core@parse.meminfo(text) do
      {:ok, {:mem_info, total, available, swap_total, swap_free} = m} ->
        %{
          total_kb: total,
          available_kb: available,
          used_kb: total - available,
          used: :hud_core@parse.mem_used_fraction(m),
          swap_total_kb: swap_total,
          swap_used_kb: swap_total - swap_free
        }

      {:error, nil} ->
        nil
    end
  end

  @doc "Bytes received and sent by every interface but lo: `{rx, tx}`."
  def net_totals(text) do
    text |> :hud_core@parse.net_dev() |> :hud_core@parse.net_totals()
  end

  @doc "hud's wifi command output as a map."
  def wifi(text) do
    {:wifi, ok, signal, ssid, links, width, dbm, bitrate} = :hud_core@parse.wifi(text)

    %{
      ok: ok,
      signal: signal,
      ssid: ssid,
      links:
        for({:link, id, freq, active} <- links, do: %{id: id, freq_mhz: freq, active: active}),
      width_mhz: width,
      dbm: dbm,
      bitrate_mbit: bitrate
    }
  end

  @doc "A CI progress line as `%{package:, done:, total:}`, or nil."
  def ci_progress(text) do
    case :hud_core@parse.ci_progress(text || "") do
      {:ok, {:progress, package, done, total}} -> %{package: package, done: done, total: total}
      {:error, nil} -> nil
    end
  end

  @doc "Build the Gleam `Progress` record back from the map, for `rate.eta_update`."
  def progress_record(%{package: p, done: d, total: t}), do: {:progress, p, d, t}

  @doc "The Gleam adaptive-sampling policy record."
  def policy(min_ms, max_ms, noise), do: {:policy, min_ms, max_ms, noise / 1}
end
