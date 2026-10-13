defmodule Jantar.Frame do
  @moduledoc """
  One dashboard frame: a snapshot of History turned into a display list
  (`Jantar.Render.DisplayList`) that either backend can draw.

  This is hud's `FbRenderer` (`~/dotfiles/bin/hud --fb`) moved to the BEAM:
  the same panels, layout and look (Solarized, polar dials with laps, fading
  dots, a glow on the newest samples, CPU core rings by tier, captions, a
  header and the CI footer). All dial geometry comes from the Gleam `polar`
  module; the backends only rasterise.

  One addition over hud, for faster sampling: a series with more samples per
  lap than there is room for dots (`polar.dense`) is drawn as a min..max band
  with a line through the mean (`polar.buckets`), so a 250 ms series reads as
  a trace rather than a blur. Sparse series keep distinct dots.

      snapshot = Frame.snapshot()
      {list, meta} = Frame.build(snapshot, width: 1440, height: 960)
  """

  alias Jantar.{Format, History, Theme}
  alias Jantar.Render.DisplayList, as: DL

  # Value rings of a dial, as a share of its radius (hud: R0; R1 is R - 7u).
  @r0_share 0.36
  # In the dense mode, one bucket per this many units of arc.
  @bucket_units 3.0
  # Fewer samples per lap than (lap length in units / this) are drawn as dots.
  @dot_spacing_units 3.0

  # Text around a focused section's dials, relative to the overview.
  @focus_text 1.8

  # ------------------------------------------------------------------ snapshot

  @series [:cpu, :clock, :mem, :rx, :tx, :temp, :power, :fan, :npu, :wifi] ++
            [
              {:link, :gateway},
              {:link, :ipv6},
              {:event, :wifi},
              {:event, :link},
              {:event, :restart},
              {:event, :npu_example}
            ] ++
            [{:swap, :in}, {:swap, :out}, {:disk, :read}, {:disk, :write}] ++
            for(d <- [:platform, :package, :cores, :graphics, :memory], do: {:rapl, d}) ++
            for(k <- [:compute, :dma, :riscv, :shave], do: {:npu, k})

  # Cutovers drawn as radial lines on the network dials.
  @network_events [{:event, :wifi}, {:event, :link}]
  # Example runs (Jantar.NpuExamples) on the NPU dials.
  @npu_events [{:event, :npu_example}]
  @sensors [
    :cpu,
    :memory,
    :swap,
    :disk,
    :net,
    :thermal,
    :fan,
    :battery,
    :charger,
    :rapl,
    :ports,
    :npu,
    :npu_counters,
    :gpu,
    :wifi,
    :link,
    :wifi_events,
    :ci_runner,
    :npu_examples
  ]

  @doc """
  Everything a frame needs, read from History's ETS tables (no messages):
  each sensor's latest values (nil while unavailable) and each series'
  samples and window.

  `scale` is `:live` (the samples), or `:day` / `:month` (History's
  archives: one row per minute for 24 hours, or per hour for 30 days, drawn
  as one lap). For an archive, `samples` holds each row's mean at the middle
  of its step, and `rows` the `{t, min, mean, max}` rows themselves.

  `{:window, ms}` (a focused section's 1, 5 or 30 minutes) draws the last
  `ms` as one lap: the samples where History keeps that long, else the
  per-minute archive rows.
  """
  def snapshot(now \\ System.monotonic_time(:millisecond), scale \\ :live) do
    gpu_series = for s <- History.series(), match?({:gpu, _}, s), do: s

    series =
      for name <- @series ++ gpu_series, info = History.info(name), into: %{} do
        {name, series_at(name, info, scale, now)}
      end

    sensors =
      for name <- @sensors, into: %{} do
        case History.sensor(name) do
          %{status: :ok, current: c} ->
            {name, c}

          # A read error from the NPU's counters is usually brief (the
          # sensor reopens them at once): keep the DMA dial, saying so,
          # rather than have it vanish and come back.
          %{status: {:unavailable, {:npu_port, why}}} when name == :npu_counters ->
            {name, %{streaming: false, retrying: why}}

          _ ->
            {name, nil}
        end
      end

    %{now: now, series: series, sensors: sensors, scale: scale}
  end

  defp series_at(name, info, :live, _now),
    do: %{samples: History.samples(name), window_ms: info.window_ms}

  defp series_at({:event, _} = name, info, _scale, now), do: series_at(name, info, :live, now)

  defp series_at(name, info, {:window, ms}, now) do
    if info.window_ms >= ms do
      window(series_at(name, info, :live, now), ms, now)
    else
      # Longer than the samples kept: one row per minute.
      %{rows: rows} = series_at(name, info, :day, now)
      rows = for {t, _, _, _} = r <- rows, now - t <= ms, do: r

      %{
        samples: for({t, _, mean, _} <- rows, do: {t, mean}),
        rows: rows,
        window_ms: ms,
        lap: true
      }
    end
  end

  defp series_at(name, _info, scale, now) do
    {:spec, step, keep} = History.scales()[scale]
    # Archive starts are wall-clock; the dials work in monotonic time.
    offset = System.system_time(:millisecond) - System.monotonic_time(:millisecond)
    mid = div(step, 2)

    rows =
      for {start, min, mean, max} <- History.archive(name, scale),
          t = min(start + mid - offset, now),
          do: {t, min, mean, max}

    %{samples: for({t, _, mean, _} <- rows, do: {t, mean}), rows: rows, window_ms: keep}
  end

  @doc """
  A live snapshot cut to its last `ms`, each series drawn as one lap (what
  `snapshot(now, {:window, ms})` does for series that keep that long; also
  for the demo snapshot).
  """
  def window(%{series: series, now: now} = snap, ms) do
    series =
      Map.new(series, fn
        {{:event, _} = name, s} -> {name, s}
        {name, s} -> {name, window(s, ms, now)}
      end)

    Map.merge(snap, %{series: series, scale: {:window, ms}})
  end

  defp window(%{samples: samples}, ms, now),
    do: %{samples: for({t, _} = s <- samples, now - t <= ms, do: s), window_ms: ms, lap: true}

  # ------------------------------------------------------------------ frame

  @doc """
  Build the display list. Options: `:width`, `:height` (pixels), `:theme`
  (default `Theme.current/0`), `:label` (shown top right, e.g. the backend),
  `:host` and `:clock` (header text; default this machine and local time),
  `:focus` (one section's title: that section alone, full screen).

  Returns `{binary, meta}`; `meta.sensors` lists the sensors behind the
  panels drawn, so the display can pace frames to the fastest of them.
  """
  def build(snap, opts) do
    w = Keyword.fetch!(opts, :width)
    h = Keyword.fetch!(opts, :height)
    c = Theme.palette(Keyword.get(opts, :theme) || Theme.current())
    u = min(w / 1440, h / 960)
    ctx = %{c: c, u: u, now: snap.now, w: w, h: h}

    margin = trunc(16 * u)
    head_h = trunc(30 * u)
    ci = snap.sensors.ci_runner
    foot_h = if ci && ci.installed, do: trunc(44 * u), else: 0

    panels = panels(snap)
    focus = if opts[:focus] in section_titles(), do: opts[:focus]
    # Zoomed, a section may draw more than its dials: the NPU its pipeline.
    extra_h = if focus == "NPU" and snap.sensors.npu, do: trunc(300 * u), else: 0
    {placed, titles} = sections(panels, w, h, margin, head_h, foot_h + extra_h, u, focus)
    # Focused dials are about twice the size: so is the text around them.
    tile_ctx = if focus, do: %{ctx | u: u * @focus_text}, else: ctx

    ops = [
      DL.fill(c.bg),
      header(ctx, snap, margin, head_h, opts),
      if(foot_h > 0,
        do: footer(ctx, ci, margin, h - foot_h - div(margin, 2), w - 2 * margin),
        else: []
      ),
      for({x, y, text, tint, tw} <- titles, do: section_title(ctx, x, y, text, tint, tw)),
      for({panel, cx, y0, d} <- placed, do: tile(tile_ctx, panel, cx, y0, d)),
      if(extra_h > 0,
        do:
          npu_diagram(
            ctx,
            snap.sensors,
            opts[:pick] || 0,
            margin,
            h - foot_h - margin - extra_h,
            w - 2 * margin,
            extra_h
          ),
        else: []
      )
    ]

    meta = %{
      sensors: placed |> Enum.map(&elem(&1, 0).sensor) |> Enum.uniq(),
      dial_size: placed |> Enum.map(&elem(&1, 3)) |> Enum.max(fn -> 0 end)
    }

    {DL.encode(w, h, ops), meta}
  end

  # ------------------------------------------------------------------ sections

  # The panels grouped as in the Quickshell dropdown: titled sections in two
  # columns, the dials of a section side by side. A list is a row of sections
  # sharing one line (the GPU's single dial beside the CPU's two).
  @columns [
    [
      [{"CPU", :yellow, ["CPU", "LOAD"]}, {"GPU", :orange, ["GPU"]}],
      {"NPU", :cyan, ["NPU", "DMA"]},
      {"MEMORY · STORAGE", :violet, ["MEM", "SWAP", "DISK"]}
    ],
    [
      {"THERMALS", :red, ["TEMP", "CLOCK", "FAN"]},
      {"POWER", :green, ["POWER", "CHIP", "PORTS"]},
      {"LINKS", :blue, ["WIFI", "NET", "LINK"]}
    ]
  ]

  @doc "The section titles, overview order: what `build/2`'s `:focus` takes."
  def section_titles,
    do: for(col <- @columns, row <- col, {text, _, _} <- List.wrap(row), do: text)

  # Lay the sections out: returns `{panel, centre x, top y, dial size}` for
  # each panel and `{x, y, text, tint, width}` for each section title. A section's
  # dials share its column's width; one cap on dial size, the largest that
  # lets both columns fit the height, keeps single dials from growing huge.
  # Focused, one section has the whole screen: a single column.
  defp sections(panels, w, h, margin, head_h, foot_h, u, focus) do
    by_title = Map.new(panels, &{panel_title(&1), &1})
    gap = trunc(18 * u)
    title_h = trunc(24 * u)
    text_h = trunc(46 * u * if(focus, do: @focus_text, else: 1))
    top = head_h + div(margin, 2)
    avail = h - top - foot_h - margin

    layout =
      case for(col <- @columns, row <- col, {^focus, _, _} = sec <- List.wrap(row), do: sec) do
        [sec] -> [[[sec]]]
        [] -> for(col <- @columns, do: Enum.map(col, &List.wrap/1))
      end

    col_w = (w - 2 * margin - gap * (length(layout) - 1)) / length(layout)

    # Each row: its sections with the panels present (empty ones dropped).
    columns =
      for column <- layout do
        for row <- column,
            secs =
              for(
                {text, tint, titles} <- row,
                members = for(t <- titles, p = by_title[t], do: p),
                members != [],
                do: {text, tint, members}
              ),
            secs != [],
            do: secs
      end

    # Anything not in a section (a new sensor) goes at the end of the shorter
    # column, so it still shows (in the overview).
    known =
      for col <- @columns, row <- col, {_, _, titles} <- List.wrap(row), t <- titles, do: t

    extra = Enum.reject(panels, &(panel_title(&1) in known))
    [left, right] = if length(columns) == 2, do: columns, else: [[], []]

    columns =
      if extra == [] or length(columns) != 2,
        do: columns,
        else: [left, right ++ [[{"MORE", :fg, extra}]]]

    # A row's dials share the column's width, whichever section they're in.
    count = fn row -> row |> Enum.map(&length(elem(&1, 2))) |> Enum.sum() end
    size = fn row, cap -> min(col_w / count.(row) - gap, cap) end

    height = fn col, cap ->
      col |> Enum.map(&(title_h + size.(&1, cap) + text_h + gap)) |> Enum.sum()
    end

    # The largest cap (in whole pixels) with both columns fitting.
    cap =
      Enum.find(trunc(col_w)..trunc(40 * u)//-4, trunc(40 * u), fn cap ->
        Enum.all?(columns, &(height.(&1, cap) <= avail))
      end)

    {placed, titles} =
      columns
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {col, i}, acc ->
        x0 = margin + i * (col_w + gap)
        # Spread spare height evenly between the rows.
        spare = max(0, avail - height.(col, cap)) / max(1, length(col))
        # A focused section sits in the middle of the screen.
        start = if focus, do: top + spare / 2, else: top

        {acc, _y} =
          Enum.reduce(col, {acc, start}, fn row, {acc, y} ->
            d = trunc(size.(row, cap))
            share = col_w / count.(row)

            # Sections in a row sit side by side, each as wide as its dials' share.
            {acc, _x} =
              Enum.reduce(row, {acc, x0}, fn {text, tint, members}, {{placed, titles}, x} ->
                here =
                  members
                  |> Enum.with_index()
                  |> Enum.map(fn {p, k} -> {p, trunc(x + share * (k + 0.5)), y + title_h, d} end)

                sec_w = share * length(members)
                # A gap between titles that share a row, so their hairlines don't meet.
                tw = if x + sec_w < x0 + col_w - 1, do: sec_w - gap, else: sec_w
                {{placed ++ here, titles ++ [{trunc(x), y, text, tint, tw}]}, x + sec_w}
              end)

            {acc, y + title_h + d + text_h + gap + spare}
          end)

        acc
      end)

    {placed, titles}
  end

  # ------------------------------------------------------------------ NPU pipeline

  # How a job runs on the NPU, drawn under its dials when zoomed. The host
  # rings a doorbell; the RISC-V control core sets up task lists and barriers;
  # then DMA, the DPU tiles and the SHAVE cores release each other through
  # hardware barriers, working out of CMX, the tiles' own SRAM. Each box glows
  # with what jantar measures for it (the dial colours): DPU and SHAVE share
  # "compute" (the counter can't split them), SHAVE also lights on its cache
  # traffic, RAM and CMX have no counter.
  defp npu_diagram(%{c: c, u: u} = ctx, sensors, pick, x, y, w, _h) do
    npu = sensors.npu
    n = sensors[:npu_counters]
    live = n != nil and n[:streaming] == true
    # Readings only while streaming; fields may be missing otherwise.
    v = if live, do: n, else: %{}
    # A rate on a log scale, as a glow from 0 to 1.
    glow = fn v, lo, hi ->
      if live and v, do: clamp((:math.log10(max(v, 1)) - lo) / (hi - lo)), else: 0
    end

    compute = if v[:compute], do: clamp(v[:compute]), else: 0

    cols = 5
    gap = 22 * u
    bw = (w - gap * (cols - 1)) / cols
    bh = 74 * u
    row_a = y + 30 * u
    row_b = row_a + bh + 64 * u
    bx = fn i -> x + i * (bw + gap) end

    boxes = [
      {0, row_a, "HOST CPU", "OpenVINO compiles the model", "to a fixed schedule", nil, :fg, 0},
      {1, row_a, "QUEUE", "jobs in shared memory;", "a doorbell wakes the NPU",
       if(npu.awake, do: "awake", else: "asleep"), :green, if(npu.awake, do: npu.load, else: 0)},
      {2, row_a, "RISC-V", "control core: task lists,", "barriers, power, errors",
       v[:riscv] && "cache #{Format.count(v[:riscv])}/s", :magenta, glow.(v[:riscv], 5.0, 8.0)},
      {0, row_b, "SYSTEM RAM", "weights, inputs, results", "", nil, :fg, 0},
      {1, row_b, "DMA", "two engines move tiles", "of data in and out",
       v[:dma] && "#{Format.count(v[:dma])}/s", :green, glow.(v[:dma], 7.0, 10.0)},
      {2, row_b, "CMX", "each tile's own SRAM;", "all work happens here", nil, :fg, 0},
      {3, row_b, "DPU", "matrix: convolutions,", "matmuls, fused activations",
       live && "compute #{Format.pct(compute)}", :blue, compute},
      {4, row_b, "SHAVE", "vector DSPs: softmax,", "norms, the unfusable",
       v[:shave] && "cache #{Format.count(v[:shave])}/s", :cyan,
       max(compute * 0.5, glow.(v[:shave], 2.0, 5.0))}
    ]

    title = 13 * u
    small = 11 * u

    box_ops =
      for {i, by, name, l1, l2, value, tint, g} <- boxes do
        x0 = bx.(i)
        col = Map.fetch!(c, tint)
        edge = DL.mix(col, c.bg, if(g > 0, do: 0.9, else: 0.45))
        body = DL.mix(col, c.bg, 0.06 + 0.32 * g)

        [
          DL.rrect(x0, by, x0 + bw, by + bh, 6 * u, edge),
          DL.rrect(x0 + 1.5 * u, by + 1.5 * u, x0 + bw - 1.5 * u, by + bh - 1.5 * u, 5 * u, body),
          DL.text(x0 + 10 * u, by + 9 * u, :left, :top, [{name, title, true, col}]),
          DL.text(x0 + bw - 10 * u, by + 10 * u, :right, :top, [
            {value || "", small, false, if(g > 0, do: col, else: c.dim)}
          ]),
          DL.text(x0 + 10 * u, by + 32 * u, :left, :top, [{l1, small, false, c.fg}]),
          DL.text(x0 + 10 * u, by + 49 * u, :left, :top, [{l2, small, false, c.dim}])
        ]
      end

    line_c = DL.mix(c.dim, c.bg, 0.8)
    mid_a = row_a + bh / 2
    mid_b = row_b + bh / 2
    right = fn i -> bx.(i) + bw end

    # Task lists: RISC-V down to a bus over the engines, a tick into each.
    bus_y = row_b - 26 * u
    risc_x = bx.(2) + bw / 2

    arrows = [
      arrow(right.(0), mid_a, bx.(1), mid_a, u, line_c, false),
      arrow(right.(1), mid_a, bx.(2), mid_a, u, line_c, false),
      arrow(right.(0), mid_b, bx.(1), mid_b, u, line_c, true),
      arrow(right.(1), mid_b, bx.(2), mid_b, u, line_c, true),
      arrow(right.(2), mid_b, bx.(3), mid_b, u, line_c, true),
      arrow(right.(3), mid_b, bx.(4), mid_b, u, line_c, true),
      DL.line(risc_x, row_a + bh, risc_x, bus_y, max(1.0, u), line_c),
      DL.line(bx.(1) + bw / 2, bus_y, bx.(4) + bw / 2, bus_y, max(1.0, u), line_c),
      for(
        i <- [1, 3, 4],
        do: arrow(bx.(i) + bw / 2, bus_y, bx.(i) + bw / 2, row_b, u, line_c, false)
      ),
      DL.text(risc_x + 8 * u, bus_y - 4 * u, :left, :bottom, [
        {"task lists", small, false, c.dim}
      ])
    ]

    # Barriers under the engines, and the fence back to the host.
    bar_y = row_b + bh + 16 * u

    notes = [
      DL.rrect(bx.(1), bar_y, right.(4), bar_y + 22 * u, 4 * u, DL.mix(c.violet, c.bg, 0.18)),
      DL.text(bx.(1) + 10 * u, bar_y + 11 * u, :left, :middle, [
        {"BARRIERS", small, true, c.violet},
        {"  hardware counters chain the tasks: each waits for its count, finishing releases the next",
         small, false, c.fg}
      ]),
      DL.text(bx.(0) + bw / 2, bar_y + 11 * u, :center, :middle, [
        {"fence → host: done", small, false, c.dim}
      ]),
      DL.text(right.(4), y + 6 * u, :right, :top, [
        {if(live, do: "lit by the live counters", else: "counters read only while the NPU works"),
         small, false, c.dim}
      ]),
      DL.text(x, y + 6 * u, :left, :top, [{"HOW A JOB RUNS", small, true, c.cyan}])
    ]

    examples =
      case sensors[:npu_examples] do
        nil ->
          []

        ex ->
          examples_panel(
            ctx,
            ex,
            pick,
            bx.(3),
            y + 22 * u,
            right.(4) - bx.(3),
            bus_y - y - 30 * u
          )
      end

    [box_ops, arrows, notes, examples]
  end

  # The example library (Jantar.NpuExamples): the catalogue with the picked
  # one marked, what's running, and each example's last engine split as a
  # bar in the diagram's colours (DPU blue, SHAVE cyan, DMA green).
  defp examples_panel(%{c: c, u: u}, ex, pick, x, y, w, h) do
    small = 11 * u
    row = 14.5 * u
    cat = ex.catalogue
    n = length(cat)
    picked = if n > 0, do: Integer.mod(pick, n)
    running = ex.state == :running

    status =
      cond do
        running and ex.count > 0 ->
          "running #{ex.index}/#{ex.count}  #{ex.label}" <> queued_note(ex[:queue])

        running ->
          "starting #{ex.example}"

        ex.state == :listing ->
          "reading the library"

        ex.error ->
          ex.error

        true ->
          "j k pick  r run  x stop"
      end

    header = [
      DL.text(x, y, :left, :top, [{"EXAMPLES", small, true, c.cyan}]),
      DL.text(x + w, y, :right, :top, [
        {status, small, false, if(running, do: c.cyan, else: c.dim)}
      ])
    ]

    bar_w = w * 0.28
    bar_x = x + w - bar_w
    # Rows for the list, less one for the picked example's use; the list
    # scrolls to keep the pick in view.
    shown = max(1, trunc((h - row) / row) - 1)
    first = if picked, do: (picked - div(shown, 2)) |> min(n - shown) |> max(0), else: 0

    lines =
      for {e, i} <- Enum.with_index(cat), i >= first, i < first + shown do
        ly = y + row * (i - first + 1) + 2 * u
        on = i == picked
        live = running and ex.example == e.name

        col =
          cond do
            live -> c.cyan
            on -> c.fg
            true -> c.dim
          end

        place = Enum.find_index(ex[:queue] || [], &(&1 == e.name))
        # More above or below the window.
        more =
          cond do
            i == first and first > 0 -> "▴ "
            i == first + shown - 1 and first + shown < n -> "▾ "
            true -> "  "
          end

        [
          DL.text(bar_x - 6 * u, ly, :right, :top, [
            {if(place, do: "queued #{place + 1}", else: ""), small, false, c.cyan}
          ]),
          DL.text(x - 12 * u, ly, :left, :top, [{more, small, false, c.dim}]),
          DL.text(x, ly, :left, :top, [
            {if(on, do: "▸ ", else: "  "), small, true, col},
            # "Fusion: which activations ...": the part before the question.
            {e.title |> String.split(":") |> hd(), small, on, col}
          ]),
          engine_bar(c, u, ex.results[e.name], bar_x, ly, bar_w, small)
        ]
      end

    # Where the picked one shows up in real use.
    use =
      case picked && Enum.at(cat, picked) do
        %{real_world: rw} when rw not in [nil, ""] ->
          DL.text(x, y + row * (shown + 1) + 4 * u, :left, :top, [
            {"used in  ", small, true, c.dim},
            {rw, small, false, c.fg}
          ])

        _ ->
          []
      end

    [header, lines, use]
  end

  defp queued_note([_ | _] = q), do: "  +#{length(q)} queued"
  defp queued_note(_), do: ""

  defp engine_bar(c, _u, nil, x, y, _w, size),
    do: DL.text(x, y, :left, :top, [{"not run yet", size, false, DL.mix(c.dim, c.bg, 0.7)}])

  defp engine_bar(c, u, result, x, y, w, size) do
    mid = y + size * 0.55

    {rects, _} =
      Enum.map_reduce([{"DPU", c.blue}, {"Shave", c.cyan}, {"DMA", c.green}], x, fn {k, kc}, x0 ->
        bw = w * Map.get(result.engines, k, 0)
        {{x0, mid - 3 * u, bw, 6 * u, kc}, x0 + bw}
      end)

    [
      DL.rects(for {_, _, bw, _, _} = r <- rects, bw > 0, do: r),
      if(result.ok,
        do: [],
        else: DL.text(x - 6 * u, y, :right, :top, [{"partial", size, false, c.orange}])
      )
    ]
  end

  defp clamp(v), do: v |> max(0.0) |> min(1.0)

  # A line with an arrowhead at the end (and the start, if both).
  defp arrow(x0, y0, x1, y1, u, rgb, both) do
    head = fn {ax, ay}, {bx, by} ->
      len = :math.sqrt((bx - ax) ** 2 + (by - ay) ** 2)
      {dx, dy} = {(bx - ax) / len, (by - ay) / len}
      s = 7 * u

      [
        {bx, by, bx - s * dx - s * 0.55 * dy, by - s * dy + s * 0.55 * dx, rgb},
        {bx, by, bx - s * dx + s * 0.55 * dy, by - s * dy - s * 0.55 * dx, rgb}
      ]
    end

    gap = 4 * u
    len = :math.sqrt((x1 - x0) ** 2 + (y1 - y0) ** 2)
    {dx, dy} = {(x1 - x0) / len, (y1 - y0) / len}
    a = {x0 + gap * dx, y0 + gap * dy}
    b = {x1 - gap * dx, y1 - gap * dy}

    DL.segments(
      [{elem(a, 0), elem(a, 1), elem(b, 0), elem(b, 1), rgb}] ++
        head.(a, b) ++ if(both, do: head.(b, a), else: []),
      max(1.0, u * 1.2)
    )
  end

  defp panel_title(%{kind: :cpu}), do: "CPU"
  defp panel_title(%{title: title}), do: title

  # A section heading, like the dropdown's StatTitle: small, bold, tinted,
  # with a hairline after it.
  defp section_title(%{c: c, u: u}, x, y, text, tint, width) do
    size = 13 * u
    # DejaVu Sans Mono: each character is about 0.6 of the size wide.
    after_text = x + (String.length(text) + 1) * size * 0.62

    [
      DL.text(x, y, :left, :top, [{text, size, true, Map.fetch!(c, tint)}]),
      DL.line(
        after_text,
        y + size * 0.6,
        x + width,
        y + size * 0.6,
        max(1.0, u),
        DL.mix(c.dim, c.bg, 0.4)
      )
    ]
  end

  # ------------------------------------------------------------------ panels (hud's panels())

  defp panels(snap) do
    s = snap.sensors
    series = snap.series
    hist = fn name -> Map.get(series, name, %{samples: [], window_ms: 300_000}) end

    values = fn name ->
      for {_t, v} <- hist.(name).samples, is_number(v), do: v
    end

    [
      s.cpu && %{kind: :cpu, sensor: :cpu, cpu: s.cpu, temp: s.thermal && s.thermal.temp_c},
      s.thermal &&
        dial(:thermal, "TEMP", :red, [{:temp, 1, :red, :red}], hist,
          period: 300_000,
          scale: {:linear, 30.0, 100.0},
          auto: 10.0,
          guides: [50, 90],
          centre: [{Format.temp(s.thermal.temp_c), :red, true}],
          info: [
            {max_text("30m max ", values.(:temp), &Format.temp/1), :fg},
            {"guides 50, 90", :muted}
          ]
        ),
      s.battery && power_panel(s.battery, s.charger, hist),
      s.net &&
        dial(:net, "NET", :blue, [{:rx, 1, :blue, :orange}, {:tx, -1, :blue, :orange}], hist,
          scale: {:log, 2.0, 8.0},
          events: @network_events,
          mirrored: true,
          guides: [1.0e3, 1.0e6],
          centre: [
            {"↓" <> Format.rate(s.net.rx), :blue, true},
            {"↑" <> Format.rate(s.net.tx), :orange, true}
          ],
          info: [
            {"↓#{Format.bytes(s.net.rx_total)} ↑#{Format.bytes(s.net.tx_total)}", :fg},
            {"since boot; log rate", :muted}
          ]
        ),
      s.memory &&
        dial(:memory, "MEM", :violet, [{:mem, 1, :violet, :violet}], hist,
          guides: [0.5, 0.75],
          centre: [
            {Format.pct(s.memory.used), :violet, true},
            {Format.kb(s.memory.used_kb), :fg, false}
          ],
          info: [
            {"#{Format.kb(s.memory.used_kb)} of #{Format.kb(s.memory.total_kb)}", :fg},
            {"swap #{Format.kb(s.memory.swap_used_kb)} of #{Format.kb(s.memory.swap_total_kb)}",
             :muted}
          ]
        ),
      s[:swap] &&
        dial(
          :swap,
          "SWAP",
          :magenta,
          [{{:swap, :in}, 1, :magenta, :magenta}, {{:swap, :out}, -1, :magenta, :magenta}],
          hist,
          scale: {:log, 0.0, 4.0},
          mirrored: true,
          guides: [10.0, 1000.0],
          centre: [
            {Format.kb(s.swap.used_kb), :magenta, true},
            {"in #{round(s.swap.in || 0)}  out #{round(s.swap.out || 0)}", :muted, false}
          ],
          info: [
            {"#{Format.kb(s.swap.used_kb)} of #{Format.kb(s.swap.total_kb)}", :fg},
            {"pages/s, in above, out below", :muted}
          ]
        ),
      s[:disk] &&
        dial(
          :disk,
          "DISK",
          :violet,
          [{{:disk, :read}, 1, :violet, :orange}, {{:disk, :write}, -1, :violet, :orange}],
          hist,
          scale: {:log, 3.0, 9.0},
          mirrored: true,
          guides: [1.0e5, 1.0e7],
          centre: [
            {"r " <> Format.rate(s.disk.read), :violet, true},
            {"w " <> Format.rate(s.disk.write), :orange, true}
          ],
          info: [
            {disk_info(s.disk), :fg},
            {top_writer(s.disk.top), :muted}
          ]
        ),
      s.npu && npu_panel(s.npu, s[:npu_counters], hist),
      s[:npu_counters] && dma_panel(s.npu_counters, hist),
      s.gpu && gpu_panel(s.gpu, hist),
      s.cpu && s.cpu.clock_ghz &&
        dial(:cpu, "CLOCK", :yellow, [{:clock, 1, :yellow, :yellow}], hist,
          period: 120_000,
          scale: {:linear, 0.0, 4.0},
          auto: 1.0,
          guides: [1, 3],
          centre: [{f1(s.cpu.clock_ghz) <> "G", :yellow, true}],
          info: [
            {"30m avg #{f1(mean(values.(:clock)) || 0)}G", :fg},
            {"mean of #{length(s.cpu.freqs_mhz)} cores", :muted}
          ]
        ),
      s.fan &&
        dial(:fan, "FAN", :cyan, [{:fan, 1, :cyan, :cyan}], hist,
          period: 300_000,
          scale: {:linear, 0.0, 6000.0},
          auto: 1000.0,
          guides: [2000, 4000],
          centre: [{"#{s.fan.rpm}", :cyan, true}, {"rpm", :muted, false}],
          info: [
            {max_text("30m max ", values.(:fan), &"#{round(&1)}"), :fg},
            {"guides 2000, 4000", :muted}
          ]
        ),
      s.wifi && s.wifi.ok != false && wifi_panel(s.wifi, hist),
      s[:link] && link_panel(s[:link], s[:wifi_events], hist),
      s[:rapl] && map_size(s.rapl) > 0 && chip_panel(s.rapl, hist),
      s[:ports] &&
        %{
          kind: :ports,
          sensor: :ports,
          title: "PORTS",
          ports: s.ports.ports,
          other: s.ports.other
        },
      s.cpu &&
        dial(:cpu, "LOAD", :yellow, [{:cpu, 1, :yellow, :yellow}], hist,
          guides: [0.5, 0.75],
          centre: [{Format.pct(s.cpu.load), :yellow, true}],
          info: [{"#{length(s.cpu.ids)} cores", :fg}, {"all cores", :muted}]
        )
    ]
    |> Enum.filter(& &1)
  end

  defp power_panel(b, charger, hist) do
    state = String.downcase(b.status)

    state =
      if b.minutes,
        do:
          state <>
            if(b.status == "Charging", do: " full in ", else: " ") <> Format.mins(b.minutes),
        else: state

    watts = charger && charger.watts

    dial(:battery, "POWER", :green, [{:power, 1, :green, :orange}], hist,
      period: 600_000,
      scale: {:log, 0.0, 2.0},
      mirrored: true,
      guides: [10],
      centre: [
        {Format.signed_watts(b.watts), if(b.watts >= 0, do: :green, else: :orange), true},
        {if(b.pct, do: "#{b.pct}%", else: ""), :fg, false}
      ],
      info: [
        {state, :fg},
        {if(watts && watts > 0, do: "charger #{round(watts)} W", else: "no charger"), :muted}
      ]
    )
  end

  defp gpu_panel(gpu, hist) do
    roles = [:orange, :violet, :cyan, :blue]

    gts =
      gpu.gts
      |> Enum.with_index()
      |> Enum.map(fn {gt, k} ->
        role = Enum.at(roles, rem(k, length(roles)))

        short =
          cond do
            String.ends_with?(gt.name, "-rc") -> "r"
            String.ends_with?(gt.name, "-mc") -> "m"
            true -> String.slice(gt.name, -2, 2)
          end

        %{gt: gt, k: k, role: role, short: short}
      end)

    centre =
      for g <- Enum.take(gts, 2),
          do:
            {if(g.k > 0, do: g.short <> " ", else: "") <> Format.pct(g.gt.busy), g.role, g.k == 0}

    mhz = Enum.map_join(gts, " ", &"#{&1.short} #{if &1.gt.mhz > 0, do: &1.gt.mhz, else: "C6"}")

    dial(:gpu, "GPU", :orange, for(g <- gts, do: {{:gpu, g.gt.name}, 1, g.role, g.role}), hist,
      scale: {:log, -3.0, 0.0},
      idle_floor: true,
      guides: [0.01, 0.1],
      centre: centre,
      info: [
        {"MHz " <> mhz, :fg},
        {if(length(gts) > 1, do: "render orange, media violet", else: gpu.driver), :muted}
      ]
    )
  end

  # The NPU's jobs (the driver's busy time, green) and, while the counters
  # run, how much of that time its compute engine actually ran (blue: the
  # NCE clock's on-share; DPU and SHAVE together).
  defp npu_panel(npu, counters, hist) do
    compute = counters && counters.streaming && counters[:compute]

    dial(
      :npu,
      "NPU",
      :green,
      [{:npu, 1, :green, :green}, {{:npu, :compute}, 1, :blue, :blue}],
      hist,
      scale: {:log, -3.0, 0.0},
      idle_floor: true,
      events: @npu_events,
      guides: [0.01, 0.1],
      centre: [
        {Format.pct(npu.load), :green, true},
        cond do
          compute -> {"compute " <> Format.pct(compute), :blue, false}
          npu.awake -> {"awake", :fg, false}
          true -> {"asleep", :muted, false}
        end
      ],
      info: [
        {"#{npu.mhz} of #{npu.max_mhz} MHz" <>
           if(npu.mem_bytes, do: "  mem " <> Format.bytes(npu.mem_bytes), else: ""), :fg},
        {if(counters, do: "green jobs, blue compute", else: ""), :muted}
      ]
    )
  end

  # What the NPU moves while it works (Level Zero counters, read only while
  # it is awake and busy): all DMA outermost, then the RISC-V control cores'
  # and the SHAVE vector cores' cache traffic, on one log scale.
  defp dma_panel(n, hist) do
    series = [
      {{:npu, :dma}, 1, :green, :green},
      {{:npu, :riscv}, 1, :magenta, :magenta},
      {{:npu, :shave}, 1, :cyan, :cyan}
    ]

    working = n.streaming and n.dma != nil

    dial(:npu_counters, "DMA", :green, series, hist,
      scale: {:log, 3.0, 10.0},
      idle_floor: true,
      events: @npu_events,
      guides: [1.0e6, 1.0e9],
      centre: [
        {if(working, do: Format.count(n.dma) <> "/s", else: "idle"),
         if(working, do: :green, else: :muted), true},
        {if(working, do: "riscv " <> Format.count(n.riscv), else: ""), :magenta, false}
      ],
      info: [
        {cond do
           n.streaming and n.nce_mhz -> "NCE #{n.nce_mhz}  DPU #{n.dpu_mhz} MHz"
           n[:retrying] -> "counters lost, retrying"
           n[:in_use_elsewhere] -> "counters in use elsewhere"
           true -> "counted while working"
         end, :fg},
        {"green DMA, magenta RISC-V, cyan SHAVE", :muted}
      ]
    )
  end

  defp wifi_panel(w, hist) do
    links =
      Enum.map_join(
        w.links,
        " ",
        &(Format.band(&1.freq_mhz) <> if(&1.active, do: "●", else: "○"))
      )

    on = w.signal >= 0

    dial(:wifi, "WIFI", :cyan, [{:wifi, 1, :cyan, :cyan}], hist,
      scale: {:linear, 0.0, 100.0},
      events: @network_events,
      guides: [50, 75],
      centre: [
        {if(on, do: "#{w.signal}%", else: if(w.ok, do: "off", else: "…")), :cyan, true},
        {if(on and w.dbm != 0, do: "#{w.dbm} dBm", else: ""), :muted, false}
      ],
      info: [
        {if(w.ssid == "", do: "offline", else: w.ssid), :fg},
        {if(on,
           do: String.trim("#{links} #{w.width_mhz}MHz #{trunc(w.bitrate_mbit)}Mb"),
           else: ""
         ), :muted}
      ]
    )
  end

  # Where the power goes, from RAPL: the whole platform outermost in the
  # scale's sense (it's the largest), the package within it, and the cores,
  # graphics and memory within that.
  @chip [
    platform: {:green, "platform"},
    package: {:orange, "package"},
    cores: {:yellow, "cores"},
    graphics: {:magenta, "graphics"},
    memory: {:violet, "memory"}
  ]

  defp chip_panel(r, hist) do
    series = for {d, {tint, _}} <- @chip, Map.has_key?(r, d), do: {{:rapl, d}, 1, tint, tint}
    watts = fn d -> if r[d], do: "#{Float.round(r[d] / 1, 1)}", else: "–" end
    {big, big_tint} = if r[:platform], do: {:platform, :green}, else: {:package, :orange}

    dial(:rapl, "CHIP", :green, series, hist,
      scale: {:log, -1.0, 2.0},
      guides: [1.0, 10.0],
      centre: [
        {watts.(big) <> " W", big_tint, true},
        {"package " <> watts.(:package), :orange, false}
      ],
      info: [
        {"cores #{watts.(:cores)}  gfx #{watts.(:graphics)}  mem #{watts.(:memory)} W", :fg},
        {"green platform, orange package", :muted}
      ]
    )
  end

  # What a bay box says: `{tint, [{text, bold?}]}`.
  defp bay_text(%{charger: %{watts: w, volts: v, amps: a}}),
    do:
      {:green,
       [
         {"charger", true},
         {"#{round(v)} V #{Float.round(a, 1)} A", false},
         {"#{round(w)} W", false}
       ]}

  defp bay_text(%{partner: true, role: :sink}), do: {:green, [{"charger", true}]}

  defp bay_text(%{devices: [_ | _] = names}),
    do: {:cyan, Enum.map(Enum.take(names, 3), &{String.slice(&1, 0, 14), true})}

  defp bay_text(%{partner: true, role: :source}),
    do: {:orange, [{"powering", true}, {"a device", false}]}

  defp bay_text(%{partner: true}), do: {:cyan, [{"connected", true}]}
  defp bay_text(_), do: {:dim, [{"empty", false}]}

  defp disk_info(d) do
    temp = if d.temp_c, do: "  #{round(d.temp_c)}°C", else: ""
    d.device <> temp
  end

  defp top_writer(nil), do: "nothing writing"
  defp top_writer({name, rate}), do: "top writer #{name} #{Format.rate(rate)}/s"

  # Is the link usable: a default route, and a gateway that answers ARP
  # (the outer ring, green), and IPv6 (an inner ring at 0.7, cyan). Each sits
  # on its ring while up and drops to the centre while down; cutovers as lines.
  defp link_panel(l, events, hist) do
    {state, tint} =
      cond do
        not l.route -> {"no route", :red}
        not l.gateway -> {"no gateway", :orange}
        true -> {"up", :green}
      end

    dial(
      :link,
      "LINK",
      :green,
      [{{:link, :gateway}, 1, :green, :green}, {{:link, :ipv6}, 0.7, :cyan, :cyan}],
      hist,
      scale: {:linear, 0.0, 1.0},
      events: @network_events,
      centre: [
        {state, tint, true},
        {if(l[:ipv6], do: "IPv6 up", else: "no IPv6"), if(l[:ipv6], do: :cyan, else: :muted),
         false}
      ],
      info: [
        {if(l.route, do: "via #{l.gateway_ip} on #{l.iface}", else: "no default route"), :fg},
        {if(events, do: "access point #{events.bssid}", else: "lines: green up, red down"),
         :muted}
      ]
    )
  end

  # A dial panel: the Gleam polar.Dial for its first series, plus what to
  # write around it.
  defp dial(sensor, title, tint, series, hist, opts) do
    {first, _, _, _} = hd(series)
    window = hist.(first).window_ms
    archive? = Map.has_key?(hist.(first), :rows)
    {lo, hi} = range(opts[:scale] || {:linear, 0.0, 1.0}, opts[:auto], hist.(first).samples)

    scale =
      case opts[:scale] do
        {:log, a, b} -> {:log, a, b}
        _ -> {:linear, lo, hi}
      end

    # An archive is one lap: 24 hours round the dial, like a sundial, or 30
    # days; so is a focused section's window.
    period =
      cond do
        archive? or hist.(first)[:lap] -> {:some, window}
        opts[:period] -> {:some, opts[:period]}
        true -> :none
      end

    %{
      kind: :dial,
      sensor: sensor,
      title: title,
      tint: tint,
      series:
        for(
          {name, sign, role, neg} <- series,
          do:
            {floor_idle(hist.(name).samples, opts), sign, role, neg,
             floor_idle_rows(hist.(name)[:rows], opts)}
        ),
      polar: :jantar_core@polar.dial(scale, opts[:mirrored] || false, window, period),
      # Every dial marks when jantar was down (a reboot or a restart).
      events:
        for(
          name <- (opts[:events] || []) ++ [{:event, :restart}],
          e <- hist.(name).samples,
          do: e
        ),
      guides: opts[:guides] || [],
      centre: opts[:centre] || [],
      info: opts[:info] || []
    }
  end

  # idle_floor: on a log scale, values below its bottom (0 = idle) have no
  # place and would leave gaps. Put them on the bottom ring instead, so an
  # idle GPU or a sleeping NPU reads as a flat trace on the inner ring, not as
  # scattered dots. Missing readings (nil) stay gaps.
  defp floor_idle(samples, opts) do
    case {opts[:idle_floor], opts[:scale]} do
      {true, {:log, a, _}} ->
        # A hair above the bottom: polar.visible wants a reach above 0.
        floor = :math.pow(10, a) * 1.05
        for {t, v} <- samples, do: {t, if(is_number(v) and v < floor, do: floor, else: v)}

      _ ->
        samples
    end
  end

  defp floor_idle_rows(nil, _opts), do: nil

  defp floor_idle_rows(rows, opts) do
    case {opts[:idle_floor], opts[:scale]} do
      {true, {:log, a, _}} ->
        floor = :math.pow(10, a) * 1.05
        lift = fn v -> if v < floor, do: floor, else: v end
        for {t, min, mean, max} <- rows, do: {t, lift.(min), lift.(mean), lift.(max)}

      _ ->
        rows
    end
  end

  defp range({:linear, lo, hi}, nil, _samples), do: {lo, hi}

  defp range({:linear, lo, hi}, step, samples) do
    :jantar_core@polar.auto_range(lo, hi, step, for({_, v} <- samples, is_number(v), do: v / 1))
  end

  defp range(_log, _auto, _samples), do: {0.0, 1.0}

  # ------------------------------------------------------------------ tiles

  defp tile(ctx, %{kind: :cpu} = p, cx, y0, d) do
    %{c: c, u: u} = ctx
    cpu = p.cpu

    tier_clocks =
      for {tier, label} <- [{"P", "P"}, {"E", "E"}, {"LP", "L"}],
          freqs = for({f, k} <- Enum.zip(cpu.freqs_mhz, cpu.kinds), k == tier, do: f),
          freqs != [],
          do: "#{label}#{f1(Enum.sum(freqs) / length(freqs) / 1000)}"

    info = [
      {if(tier_clocks == [], do: "", else: Enum.join(tier_clocks, " ") <> "G"), :fg},
      {if(List.first(cpu.kinds, "") != "", do: "rings: P in, LP out", else: ""), :muted}
    ]

    [
      cpu_rings(ctx, cpu, cx, y0 + d / 2, d),
      DL.text(cx, y0 + d / 2 - 2 * d / 150, :center, :bottom, [
        {Format.pct(cpu.load), 15 * d / 150, true, c.fg}
      ]),
      if(p.temp,
        do:
          DL.text(cx, y0 + d / 2, :center, :top, [
            {Format.temp(p.temp), 10 * d / 150, false, c.red}
          ]),
        else: []
      ),
      captions(
        ctx,
        cx,
        y0 + d + trunc(4 * u),
        [{"CPU", :yellow, true}, {"  " <> Format.pct(cpu.load), :fg, false}],
        info
      )
    ]
  end

  # The four USB-C bays as seen from above: left and right sides, back
  # (hinge) on top. Each box says what's in it.
  defp tile(ctx, %{kind: :ports} = p, cx, y0, d) do
    %{c: c, u: u} = ctx
    gap = 8 * u
    {bw, bh} = {(d - gap) / 2, (d * 0.8 - gap) / 2}
    x0 = cx - d / 2
    top = y0 + d * 0.1
    by_port = Map.new(p.ports, &{&1.port, &1})
    layout = [{"port3", 0, 0}, {"port0", 1, 0}, {"port2", 0, 1}, {"port1", 1, 1}]

    boxes =
      for {port, col, row} <- layout, bay = by_port[port] do
        x = x0 + col * (bw + gap)
        y = top + row * (bh + gap)
        {tint, lines} = bay_text(bay)
        size = 11 * u

        [
          DL.rects([{x, y, bw, bh, DL.mix(Map.fetch!(c, tint), c.bg, 0.18)}]),
          DL.text(x + bw / 2, y + 4 * u, :center, :top, [{bay.bay, 10 * u, false, c.dim}]),
          for {{text, bold}, k} <- Enum.with_index(lines) do
            DL.text(
              x + bw / 2,
              y + bh / 2 + (k - (length(lines) - 1) / 2) * size * 1.3,
              :center,
              :middle,
              [
                {text, size, bold, Map.fetch!(c, if(tint == :dim, do: :dim, else: tint))}
              ]
            )
          end
        ]
      end

    other = p.other

    [
      boxes,
      captions(
        ctx,
        cx,
        y0 + d + trunc(4 * u),
        [{"PORTS", :green, true}],
        [
          {"seen from above, hinge at the top", :fg},
          {if(other == [], do: "", else: "unmapped: " <> Enum.join(other, ", ")), :muted}
        ]
      )
    ]
  end

  defp tile(ctx, %{kind: :dial} = p, cx, y0, d) do
    laps = :jantar_core@polar.laps(p.polar)
    {:dial, _scale, _mirrored, window, period} = p.polar
    lap_text = if laps > 1, do: "#{laps} laps of #{mins(period)}", else: mins(window)

    [
      dial_face(ctx, p, cx - div(d, 2) + d / 2, y0 + d / 2, d),
      centre(ctx, p.centre, cx, y0 + div(d, 2), d),
      captions(
        ctx,
        cx,
        y0 + d + trunc(4 * ctx.u),
        [{p.title, p.tint, true}, {"  " <> lap_text, :muted, false}],
        p.info
      )
    ]
  end

  defp mins(ms) when ms >= 2 * 86_400_000, do: "#{round(ms / 86_400_000)} days"
  defp mins(ms) when ms >= 2 * 3_600_000, do: "#{round(ms / 3_600_000)} h"
  defp mins(ms) when ms >= 60_000, do: "#{round(ms / 60_000)} min"
  defp mins(ms), do: "#{div(ms, 1000)} s"

  defp captions(%{c: c, u: u}, cx, ty, title, info) do
    lines = info |> Enum.reject(fn {t, _} -> t in [nil, ""] end) |> Enum.take(2)

    [
      DL.text(
        cx,
        ty,
        :center,
        :top,
        for({t, role, bold} <- title, do: {t, 11 * u, bold, c[role]})
      ),
      for {{t, role}, j} <- Enum.with_index(lines) do
        DL.text(cx, ty + trunc((15 + 13 * j) * u), :center, :top, legend(c, t, 10 * u, role))
      end
    ]
  end

  @colour_words ~w(yellow orange red magenta violet blue cyan green)

  # A legend line ("green DMA, magenta RISC-V, cyan SHAVE") with each phrase
  # in the colour it names, so the words match the traces. A lead-in before
  # a colon ("lines: green up, red down") and phrases naming no colour keep
  # the line's own colour.
  # Only the muted legend lines: others carry live text (an SSID could say "blue").
  defp legend(c, text, size, role) when role != :muted, do: [{text, size, false, c[role]}]

  defp legend(c, text, size, role) do
    {lead, rest} =
      case String.split(text, ": ", parts: 2) do
        [l, r] -> {l <> ": ", r}
        [r] -> {"", r}
      end

    phrases =
      rest
      |> String.split(", ")
      |> Enum.map(fn phrase ->
        colour = phrase |> String.split(" ") |> Enum.find(&(&1 in @colour_words))
        {phrase, if(colour, do: c[String.to_existing_atom(colour)], else: c[role])}
      end)

    parts =
      phrases
      |> Enum.map(fn {t, col} -> {t, size, false, col} end)
      |> Enum.intersperse({", ", size, false, c[role]})

    [{lead, size, false, c[role]} | parts]
  end

  # The value in the middle of a dial: the first line big, the rest smaller.
  defp centre(%{c: c, u: u}, lines, cx, cy, d) do
    lines = Enum.reject(lines, fn {t, _, _} -> t in [nil, ""] end)
    big = max(11 * u, d * 0.085)
    sizes = for k <- 0..(length(lines) - 1)//1, do: if(k == 0, do: big, else: big * 0.75)
    y0 = cy - Enum.sum(sizes) * 1.15 / 2

    {ops, _} =
      Enum.zip(lines, sizes)
      |> Enum.map_reduce(y0, fn {{t, role, bold}, size}, y ->
        {DL.text(cx, y, :center, :top, [{t, size, bold, c[role]}]), y + size * 1.15}
      end)

    ops
  end

  # ------------------------------------------------------------------ a polar dial

  defp dial_face(ctx, p, cx, cy, d) do
    %{c: c, u: u} = ctx
    {:dial, _scale, mirrored, window, period} = p.polar
    r = d / 2
    r1 = r - 7 * u
    r0 = r * @r0_share
    line_w = max(1, trunc(u))
    at = fn rad, a -> {cx + rad * :math.cos(a), cy + rad * :math.sin(a)} end

    tick = :jantar_core@polar.tick_ms(period)

    ticks =
      for t <- 0..(period - 1)//tick do
        a = :jantar_core@polar.angle(t, period)
        {x0, y0} = at.(r - 4 * u, a)
        {x1, y1} = at.(r - 1 * u, a)
        DL.line(x0, y0, x1, y1, line_w, DL.mix(c.dim, c.bg, 0.5))
      end

    gcol = DL.mix(c.dim, c.bg, 0.45)

    guides =
      for g <- p.guides, v <- if(mirrored, do: [g, -g], else: [g]) do
        gr = :jantar_core@polar.radius(p.polar, v / 1, r0, r1)
        n = max(12, trunc(2 * :math.pi() * gr / (4 * u)))

        for k <- 0..(n - 1) do
          {x, y} = at.(gr, k / n * 2 * :math.pi())
          {x - u / 2, y - u / 2, u, u, gcol}
        end
      end

    {samples, glows} = plot_series(ctx, p, cx, cy, r0, r1, window, period)

    [
      ticks,
      DL.ring(cx, cy, r0, line_w, DL.mix(c.dim, c.bg, 0.25)),
      if(mirrored,
        do:
          DL.ring(cx, cy, :jantar_core@polar.zero_ring(r0, r1), line_w, DL.mix(c.dim, c.bg, 0.6)),
        else: []
      ),
      DL.rects(List.flatten(guides)),
      DL.line(cx, cy - r0, cx, cy - r + u, line_w, DL.mix(c.dim, c.bg, 0.5)),
      cutovers(ctx, p[:events] || [], cx, cy, r0, r1, window, period),
      samples,
      glow(ctx, glows)
    ]
  end

  # Every series of a dial: dots when sparse, a band and mean line when
  # dense. Returns the drawing ops and the newest samples to glow (all
  # series' newest three, oldest first so the newest end up on top).
  defp plot_series(ctx, p, cx, cy, r0, r1, window, period) do
    %{c: c, u: u, now: now} = ctx
    laps = :jantar_core@polar.laps(p.polar)
    lap_units = 2 * :math.pi() * ((r0 + r1) / 2) / u
    geo = %{cx: cx, cy: cy, r0: r0, r1: r1, window: window, period: period}

    results =
      for {samples, sign, role, neg, rows} <- p.series do
        points = for {t, v} <- samples, is_number(v), do: {t, v * sign / 1}
        {older, newest} = Enum.split(points, -3)

        glows =
          for {sample, rank} <- newest |> Enum.reverse() |> Enum.with_index(),
              {:some, {rad, a}} <- [:jantar_core@polar.place(p.polar, now, sample, r0, r1)] do
            {rank, cx + rad * :math.cos(a), cy + rad * :math.sin(a),
             color(c, role, neg, elem(sample, 1))}
          end

        ops =
          cond do
            rows != nil ->
              archive_band(ctx, p.polar, rows, sign, geo, role, neg)

            :jantar_core@polar.dense(length(points), laps, lap_units / @dot_spacing_units) ->
              bucket_ms = max(1, round(period * @bucket_units / lap_units))
              band(ctx, p.polar, older, bucket_ms, geo, role, neg)

            true ->
              dots(ctx, p.polar, older, geo, role, neg)
          end

        {ops, glows}
      end

    glows = results |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort_by(&elem(&1, 0), :desc)
    {Enum.map(results, &elem(&1, 0)), glows}
  end

  # Sparse: a square per sample, fading with age.
  defp dots(%{c: c, u: u, now: now}, polar, points, geo, role, neg) do
    squares =
      for {t, v} = sample <- points,
          {:some, {rad, a}} <- [:jantar_core@polar.place(polar, now, sample, geo.r0, geo.r1)] do
        x = geo.cx + rad * :math.cos(a)
        y = geo.cy + rad * :math.sin(a)

        {x - u, y - u, 2 * u, 2 * u,
         DL.mix(color(c, role, neg, v), c.bg, fade(now - t, geo.window))}
      end

    DL.rects(squares)
  end

  # Dense: per bucket a radial stroke from min to max (faint), and a line
  # through the means, one polyline per lap.
  defp band(%{now: now} = ctx, polar, points, bucket_ms, geo, role, neg) do
    raw = :jantar_core@polar.buckets(points, now, bucket_ms)
    band_buckets(ctx, polar, raw, bucket_ms, geo, role, neg)
  end

  # An archive's rows are buckets already: one per step, with min, mean and
  # max. A missing step (it wasn't running) breaks the line.
  defp archive_band(%{now: now} = ctx, polar, rows, sign, geo, role, neg) do
    step =
      case rows do
        [{t1, _, _, _}, {t2, _, _, _} | _] -> max(1, t2 - t1)
        _ -> 60_000
      end

    raw =
      for {t, min, mean, max} <- rows do
        {a, b} = {min * sign, max * sign}
        {:bucket, now - t, Kernel.min(a, b), Kernel.max(a, b), mean * sign, 1}
      end

    band_buckets(ctx, polar, raw, step, geo, role, neg)
  end

  defp band_buckets(%{c: c, u: u}, polar, raw, bucket_ms, geo, role, neg) do
    buckets =
      for {:bucket, age, lo, hi, mean, _count} <- raw,
          :jantar_core@polar.visible(polar, lo) or :jantar_core@polar.visible(polar, hi) do
        a = :jantar_core@polar.angle(age, geo.period)
        col = color(c, role, neg, mean)
        t = fade(age, geo.window)
        r_lo = :jantar_core@polar.radius(polar, lo, geo.r0, geo.r1)
        r_hi = :jantar_core@polar.radius(polar, hi, geo.r0, geo.r1)
        r_mean = :jantar_core@polar.radius(polar, mean, geo.r0, geo.r1)

        %{
          lap: :jantar_core@polar.lap(age, geo.period),
          age: age,
          seg:
            {geo.cx + r_lo * :math.cos(a), geo.cy + r_lo * :math.sin(a),
             geo.cx + r_hi * :math.cos(a), geo.cy + r_hi * :math.sin(a),
             DL.mix(col, c.bg, t * 0.45)},
          point: {geo.cx + r_mean * :math.cos(a), geo.cy + r_mean * :math.sin(a)},
          line_color: DL.mix(col, c.bg, t)
        }
      end

    lines =
      buckets
      |> split_runs(bucket_ms)
      |> Enum.map(fn lap ->
        DL.polyline(Enum.map(lap, & &1.point), max(1.0, 1.2 * u), List.last(lap).line_color)
      end)

    [DL.segments(Enum.map(buckets, & &1.seg), @bucket_units * u), lines]
  end

  # Runs of buckets to join with one line: same lap, and no missing bucket
  # in between (a gap, or values a log scale doesn't show, such as idle).
  defp split_runs(buckets, bucket_ms) do
    buckets
    |> Enum.chunk_while(
      [],
      fn b, run ->
        case run do
          [prev | _] when prev.lap != b.lap or prev.age - b.age > bucket_ms * 1.5 ->
            {:cont, Enum.reverse(run), [b]}

          _ ->
            {:cont, [b | run]}
        end
      end,
      fn
        [] -> {:cont, []}
        run -> {:cont, Enum.reverse(run), []}
      end
    )
  end

  # Events as radial lines across the dial at the moment they happened:
  # network cutovers green for coming up (Wi-Fi connected or roamed, route,
  # gateway or IPv6 back), red for going down; and on every dial, where
  # jantar went down and came back, in the foreground colour for a reboot
  # and dimmer for a service restart. They fade with age like samples.
  defp cutovers(%{c: c, u: u, now: now}, events, cx, cy, r0, r1, window, period) do
    for {t, code} <- events, is_number(code), now - t >= 0, now - t < window do
      a = :jantar_core@polar.angle(now - t, period)

      col =
        cond do
          abs(code) == 10 -> c.fg
          abs(code) == 11 -> c.dim
          # An NPU example starting and ending.
          code == 20 -> c.cyan
          code == 21 -> c.violet
          code > 0 -> c.green
          true -> c.red
        end

      DL.line(
        cx + r0 * :math.cos(a),
        cy + r0 * :math.sin(a),
        cx + r1 * :math.cos(a),
        cy + r1 * :math.sin(a),
        max(1.0, 1.5 * u),
        DL.mix(col, c.bg, fade(now - t, window) * 0.8)
      )
    end
  end

  # hud's fading: opacity 1 for new samples down to 0.2 at the end of the window.
  defp fade(age_ms, window_ms), do: 1 - 0.8 * :math.sqrt(min(1.0, max(0, age_ms) / window_ms))

  # The newest samples: round, with a soft halo (hud's radial gradient).
  defp glow(%{c: c, u: u}, glows) do
    circles =
      for {rank, x, y, col} <- glows do
        r = (2.2 - rank * 0.4) * u

        halo =
          for k <- 6..1//-1,
              do: {x, y, r * (1 + 2 * k / 6), DL.mix(col, c.bg, 0.5 * (1 - k / 6) + 0.06)}

        halo ++ [{x, y, r, col}]
      end

    DL.circles(List.flatten(circles))
  end

  defp color(c, _role, neg, v) when v < 0, do: c[neg]
  defp color(c, role, _neg, _v), do: c[role]

  # ------------------------------------------------------------------ CPU core rings

  # The bar's core rings (hud's cpu_rings): a ring per tier, P innermost, a
  # segment per core filled by its load, and a tick outside each segment
  # whose length is the core's clock against its maximum.
  defp cpu_rings(%{c: c}, cpu, cx, cy, d) do
    f = d / 150
    tiers = Enum.filter(["P", "E", "LP", ""], &(&1 in cpu.kinds))
    {start0, sweep} = {-:math.pi() / 2 + 0.25, 2 * :math.pi() - 0.5}

    {lw, r_first, step} =
      if length(tiers) > 3, do: {6 * f, 24 * f, 12 * f}, else: {8 * f, 30 * f, 16 * f}

    tiers
    |> Enum.with_index()
    |> Enum.map(fn {tier, i} ->
      r = r_first + i * step
      cores = for {k, core} <- Enum.with_index(cpu.kinds), k == tier, do: core
      seg = sweep / length(cores)
      # Pillow draws an arc's width inside its box: the stroke is centred at r - lw/2.
      rc = r - lw / 2

      segments =
        for {core, j} <- Enum.with_index(cores) do
          a0 = start0 + j * seg + 0.035
          span = seg - 0.07
          load = (Enum.at(cpu.core_loads, core) || 0.0) |> max(0.0) |> min(1.0)
          mx = Enum.at(cpu.max_mhz, core) || 0
          freq = Enum.at(cpu.freqs_mhz, core)

          [
            DL.arc(cx, cy, rc, a0, a0 + span, lw, DL.mix(c.dim, c.bg, 0.22)),
            if(load > 0.005,
              do: DL.arc(cx, cy, rc, a0, a0 + max(0.03, span * load), lw, c[load_role(load)]),
              else: []
            ),
            if mx > 0 and freq do
              share = min(1.0, max(0.0, freq / mx))
              am = a0 + span / 2
              ra = r + lw / 2 + f
              rb = ra + f + 5 * f * share

              DL.line(
                cx + ra * :math.cos(am),
                cy + ra * :math.sin(am),
                cx + rb * :math.cos(am),
                cy + rb * :math.sin(am),
                max(1, trunc(1.5 * f)),
                DL.mix(c.fg, c.bg, 0.75)
              )
            else
              []
            end
          ]
        end

      label =
        if tier != "",
          do: DL.text(cx, cy - r, :center, :middle, [{tier, 8 * f, true, c.muted}]),
          else: []

      [segments, label]
    end)
  end

  defp load_role(l) when l < 0.25, do: :green
  defp load_role(l) when l < 0.5, do: :yellow
  defp load_role(l) when l < 0.75, do: :orange
  defp load_role(_), do: :red

  # ------------------------------------------------------------------ header and footer

  defp header(%{c: c, u: u, w: w}, snap, margin, head_h, opts) do
    host = Keyword.get_lazy(opts, :host, &hostname/0)
    clock = Keyword.get_lazy(opts, :clock, &local_time/0)
    bat = snap.sensors.battery
    wifi = snap.sensors.wifi
    size = 13 * u
    y = trunc(8 * u)

    parts =
      [{"jantar", c.cyan, true}, {"  " <> host, c.muted, false}, {"  " <> clock, c.fg, false}] ++
        if(bat && bat.pct,
          do: [{"   battery #{bat.pct}%  #{Format.signed_watts(bat.watts)}", c.green, false}],
          else: []
        ) ++
        if(wifi && wifi.ssid != "", do: [{"   " <> wifi.ssid, c.cyan, false}], else: [])

    [
      DL.text(margin, y, :left, :top, for({t, col, bold} <- parts, do: {t, size, bold, col})),
      DL.text(w - margin, y, :right, :top, [
        {Keyword.get(opts, :label, ""), 11 * u, false, c.muted}
      ]),
      DL.line(margin, head_h, w - margin, head_h, max(1, trunc(u)), c.surface)
    ]
  end

  defp local_time do
    {_date, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string()
  end

  # The CI runner's line and build progress bar (hud's footer).
  defp footer(%{c: c, u: u}, ci, x, y, w) do
    rule = DL.line(x, y, x + w, y, max(1, trunc(u)), c.surface)
    y = y + trunc(6 * u)

    parts =
      cond do
        ci.job ->
          step =
            cond do
              ci.step != "" -> [{"   " <> ci.step, :fg, false}]
              not ci.readable -> [{"   (ci-status not readable)", :muted, false}]
              true -> []
            end

          [{"CI ", :cyan, true}, {"● job " <> Format.age(ci.job), :cyan, false}] ++ step

        ci.active ->
          [{"CI ", :cyan, true}, {"○ idle, waiting for a job", :muted, false}]

        ci.failed ->
          [{"CI ", :red, true}, {"failed", :red, false}]

        true ->
          [{"CI ", :muted, true}, {"stopped", :muted, false}]
      end

    status =
      DL.text(x, y, :left, :top, for({t, role, bold} <- parts, do: {t, 12 * u, bold, c[role]}))

    [rule, status, progress_bar(c, u, ci.progress, ci.eta, x, y + trunc(18 * u), w)]
  end

  defp progress_bar(_c, _u, nil, _eta, _x, _y, _w), do: []

  defp progress_bar(c, u, p, eta, x, by, w) do
    pkg = p.package

    label =
      cond do
        String.contains?(pkg, "llvm") -> "LLVM"
        String.contains?(pkg, "compiler") -> "compiler"
        true -> pkg
      end

    tail =
      "#{trunc(p.done)} / #{trunc(p.total)}  #{trunc(p.done / p.total * 100)}%" <>
        if(eta, do: "   ETA " <> Format.age(eta), else: "")

    size = 11 * u
    bx0 = x + text_width(label <> "  ", size)
    bx1 = x + w - text_width("  " <> tail, size)
    bh = trunc(8 * u)
    top = by + trunc(3 * u)
    fx = bx0 + (bx1 - bx0) * p.done / p.total

    [
      DL.text(x, by, :left, :top, [{label, size, true, c.cyan}]),
      DL.rrect(bx0, top, bx1, top + bh, div(bh, 2), c.surface),
      if(fx > bx0 + bh, do: DL.rrect(bx0, top, fx, top + bh, div(bh, 2), c.cyan), else: []),
      DL.text(x + w, by, :right, :top, [{tail, size, false, c.fg}])
    ]
  end

  # DejaVu Sans Mono is monospaced: every glyph advances 1233/2048 em.
  defp text_width(text, size), do: String.length(text) * size * 1233 / 2048

  # ------------------------------------------------------------------ helpers

  defp f1(nil), do: "…"
  defp f1(x), do: :erlang.float_to_binary(x / 1, decimals: 1)

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp max_text(_prefix, [], _fun), do: ""
  defp max_text(prefix, values, fun), do: prefix <> fun.(Enum.max(values))

  # From the kernel, not :inet.gethostname/0: that needs an IP socket, which
  # the sandboxed service can't open, and then answers "nohost.nodomain".
  @doc false
  def hostname do
    case :file.read_file("/proc/sys/kernel/hostname", [:raw]) do
      {:ok, name} -> String.trim(name)
      {:error, _} -> :inet.gethostname() |> elem(1) |> to_string()
    end
  end
end
