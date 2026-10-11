defmodule Mix.Tasks.Jantar.Png do
  @shortdoc "Render one dashboard frame to a PNG with either backend"
  @moduledoc """
  Draws one frame and saves it as a PNG: no framebuffer needed.

      mix jantar.png                                  rust backend, live data, 1440x960
      mix jantar.png --backend cairo --out cairo.png --size 2880x1920
      mix jantar.png --demo                           the deterministic demo snapshot
      mix jantar.png --theme light --repeat 20        time 20 renders, report the median
      mix jantar.png --demo --focus NETWORK --window 1  one section full screen, last minute

  `--focus` takes a section title (CPU, NETWORK, "GPU · NPU", ...) and
  `--window` minutes (default 5), as the dashboard's zoom keys do.

  Live data needs the sensors to have sampled a while; `--wait` ms (default
  3000) is how long to let them run first.
  """
  use Mix.Task

  alias Jantar.{Frame, Render}

  @switches [
    backend: :string,
    out: :string,
    size: :string,
    demo: :boolean,
    theme: :string,
    wait: :integer,
    repeat: :integer,
    focus: :string,
    window: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    backend = choice(opts[:backend] || "rust", ~w(rust cairo))
    out = opts[:out] || "hud-#{backend}.png"
    {w, h} = parse_size(opts[:size] || "1440x960")
    theme = if opts[:theme], do: choice(opts[:theme], ~w(dark light))

    if opts[:demo] do
      Mix.Task.run("app.config")
      {:ok, _} = Application.ensure_all_started(:logger)
    else
      Mix.Task.run("app.start")
      Process.sleep(opts[:wait] || 3000)
    end

    window = {:window, (opts[:window] || 5) * 60_000}

    snapshot =
      case {opts[:demo], opts[:focus]} do
        {true, nil} -> Frame.Demo.snapshot()
        {true, _} -> Frame.window(Frame.Demo.snapshot(), elem(window, 1))
        {_, nil} -> Frame.snapshot()
        {_, _} -> Frame.snapshot(System.monotonic_time(:millisecond), window)
      end

    if opts[:focus] && opts[:focus] not in Frame.section_titles(),
      do: Mix.raise("--focus: one of #{Enum.join(Frame.section_titles(), ", ")}")

    label = Atom.to_string(backend)
    # The demo pins the header, so its frames are reproducible.
    fixed = if opts[:demo], do: [host: "hadron", clock: "12:00:00"], else: []
    # The demo is dark unless asked; live frames follow the desktop (Theme).
    fixed = fixed ++ [theme: theme || if(opts[:demo], do: :dark)]

    {build_us, {list, _meta}} =
      :timer.tc(fn ->
        Frame.build(snapshot, [width: w, height: h, label: label, focus: opts[:focus]] ++ fixed)
      end)

    {:ok, server} = Render.start_link(backend)
    times = for _ <- 1..(opts[:repeat] || 1), do: elem(Render.png(server, list, out), 1)
    median = times |> Enum.sort() |> Enum.at(div(length(times), 2))

    Mix.shell().info(
      "#{out}: #{w}x#{h} #{backend}, frame built in #{ms(build_us)} ms on the BEAM " <>
        "(#{byte_size(list)} bytes), drawn in #{ms(median)} ms (median of #{length(times)})"
    )
  end

  @doc false
  def choice(value, allowed) do
    if value in allowed,
      do: String.to_atom(value),
      else: Mix.raise("expected one of #{Enum.join(allowed, ", ")}, got #{value}")
  end

  @doc false
  def parse_size(s) do
    [w, h] = s |> String.downcase() |> String.split("x") |> Enum.map(&String.to_integer/1)
    {w, h}
  end

  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1)
end
