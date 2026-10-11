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

  # ------------------------------------------------------------------ snapshot

  @series [:cpu, :clock, :mem, :rx, :tx, :temp, :power, :fan, :npu, :wifi]
  @sensors [
    :cpu,
    :memory,
    :net,
    :thermal,
    :fan,
    :battery,
    :charger,
    :npu,
    :gpu,
    :wifi,
    :ci_runner
  ]

  @doc """
  Everything a frame needs, read from History's ETS tables (no messages):
  each sensor's latest values (nil while unavailable) and each series'
  samples and window.
  """
  def snapshot(now \\ System.monotonic_time(:millisecond)) do
    gpu_series = for s <- History.series(), match?({:gpu, _}, s), do: s

    series =
      for name <- @series ++ gpu_series, info = History.info(name), into: %{} do
        {name, %{samples: History.samples(name), window_ms: info.window_ms}}
      end

    sensors =
      for name <- @sensors, into: %{} do
        case History.sensor(name) do
          %{status: :ok, current: c} -> {name, c}
          _ -> {name, nil}
        end
      end

    %{now: now, series: series, sensors: sensors}
  end

  # ------------------------------------------------------------------ frame

  @doc """
  Build the display list. Options: `:width`, `:height` (pixels), `:theme`
  (default `Theme.current/0`), `:label` (shown top right, e.g. the backend),
  `:host` and `:clock` (header text; default this machine and local time).

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
    {tiles, d} = grid(length(panels), w, h, margin, head_h, foot_h, u)

    ops = [
      DL.fill(c.bg),
      header(ctx, snap, margin, head_h, opts),
      if(foot_h > 0,
        do: footer(ctx, ci, margin, h - foot_h - div(margin, 2), w - 2 * margin),
        else: []
      ),
      Enum.zip_with(panels, tiles, fn panel, {cx, y0} -> tile(ctx, panel, cx, y0, d) end)
    ]

    meta = %{sensors: panels |> Enum.map(& &1.sensor) |> Enum.uniq(), dial_size: d}
    {DL.encode(w, h, ops), meta}
  end

  # The biggest dial size whose grid of tiles fits (hud's FbRenderer.render):
  # returns each tile's centre x and top y, and the dial diameter.
  defp grid(count, w, h, margin, head_h, foot_h, u) do
    {ax, ay} = {margin, head_h + div(margin, 2)}
    {aw, ah} = {w - 2 * margin, h - ay - foot_h - margin}
    text_h = trunc(46 * u)
    gap = trunc(18 * u)

    {d, cols, rows} =
      Enum.reduce(1..max(count, 1), nil, fn cols, best ->
        rows = div(count + cols - 1, cols)
        d = min(aw / cols - gap, ah / max(rows, 1) - text_h - gap)
        if best == nil or d > elem(best, 0), do: {d, cols, rows}, else: best
      end)

    d = trunc(d)
    {tw, th} = {aw / cols, ah / max(rows, 1)}

    tiles =
      for i <- 0..(count - 1)//1 do
        {col, row} = {rem(i, cols), div(i, cols)}
        in_row = min(cols, count - row * cols)
        x0 = ax + (aw - in_row * tw) / 2 + col * tw
        y0 = ay + row * th + (th - d - text_h) / 2
        {trunc(x0 + tw / 2), trunc(y0)}
      end

    {tiles, d}
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
      s.npu &&
        dial(:npu, "NPU", :green, [{:npu, 1, :green, :green}], hist,
          scale: {:log, -3.0, 0.0},
          guides: [0.01, 0.1],
          centre: [
            {Format.pct(s.npu.load), :green, true},
            {if(s.npu.awake, do: "awake", else: "asleep"), if(s.npu.awake, do: :fg, else: :muted),
             false}
          ],
          info: [
            {"#{s.npu.mhz} of #{s.npu.max_mhz} MHz", :fg},
            {if(s.npu.mem_bytes, do: "mem " <> Format.bytes(s.npu.mem_bytes), else: ""), :muted}
          ]
        ),
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
      s.cpu &&
        dial(:cpu, "LOAD", :yellow, [{:cpu, 1, :yellow, :yellow}], hist,
          guides: [0.5, 0.75],
          centre: [{Format.pct(s.cpu.load), :yellow, true}],
          info: [{"#{length(s.cpu.ids)} cores", :fg}, {"all cores, 5 min", :muted}]
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
      guides: [0.01, 0.1],
      centre: centre,
      info: [
        {"MHz " <> mhz, :fg},
        {if(length(gts) > 1, do: "render orange, media violet", else: gpu.driver), :muted}
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

  # A dial panel: the Gleam polar.Dial for its first series, plus what to
  # write around it.
  defp dial(sensor, title, tint, series, hist, opts) do
    {first, _, _, _} = hd(series)
    window = hist.(first).window_ms
    {lo, hi} = range(opts[:scale] || {:linear, 0.0, 1.0}, opts[:auto], hist.(first).samples)

    scale =
      case opts[:scale] do
        {:log, a, b} -> {:log, a, b}
        _ -> {:linear, lo, hi}
      end

    period = if opts[:period], do: {:some, opts[:period]}, else: :none

    %{
      kind: :dial,
      sensor: sensor,
      title: title,
      tint: tint,
      series: for({name, sign, role, neg} <- series, do: {hist.(name).samples, sign, role, neg}),
      polar: :jantar_core@polar.dial(scale, opts[:mirrored] || false, window, period),
      guides: opts[:guides] || [],
      centre: opts[:centre] || [],
      info: opts[:info] || []
    }
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
        DL.text(cx, ty + trunc((15 + 13 * j) * u), :center, :top, [{t, 10 * u, false, c[role]}])
      end
    ]
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
        do: DL.ring(cx, cy, :jantar_core@polar.zero_ring(r0, r1), line_w, DL.mix(c.dim, c.bg, 0.6)),
        else: []
      ),
      DL.rects(List.flatten(guides)),
      DL.line(cx, cy - r0, cx, cy - r + u, line_w, DL.mix(c.dim, c.bg, 0.5)),
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
      for {samples, sign, role, neg} <- p.series do
        points = for {t, v} <- samples, is_number(v), do: {t, v * sign / 1}
        {older, newest} = Enum.split(points, -3)

        glows =
          for {sample, rank} <- newest |> Enum.reverse() |> Enum.with_index(),
              {:some, {rad, a}} <- [:jantar_core@polar.place(p.polar, now, sample, r0, r1)] do
            {rank, cx + rad * :math.cos(a), cy + rad * :math.sin(a),
             color(c, role, neg, elem(sample, 1))}
          end

        ops =
          if :jantar_core@polar.dense(length(points), laps, lap_units / @dot_spacing_units) do
            bucket_ms = max(1, round(period * @bucket_units / lap_units))
            band(ctx, p.polar, older, bucket_ms, geo, role, neg)
          else
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
  defp band(%{c: c, u: u, now: now}, polar, points, bucket_ms, geo, role, neg) do
    buckets =
      for {:bucket, age, lo, hi, mean, _count} <- :jantar_core@polar.buckets(points, now, bucket_ms),
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
    host = Keyword.get_lazy(opts, :host, fn -> :inet.gethostname() |> elem(1) |> to_string() end)
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
end
