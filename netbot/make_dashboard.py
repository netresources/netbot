#!/usr/bin/env python3
"""Build the static dashboard (HTML, stdlib only) and a PNG snapshot (matplotlib, optional).

Output: <data_dir>/../dashboard/index.html (local, self-contained, auto-refresh 5 min)
        <sync_dir>/dashboard.png (for the weekly report)
Usage:  make_dashboard.py [--example] [--png PATH]

Look and feel come only from the shipped theme files (netbot/theme/, read by theme_tokens.py): the HTML uses
the nb-* classes and var(--nb-*) / var(--metric-*), the PNG uses colors parsed from tokens.css. No color
values are written in this file; tests/test_dashboard.py fails if one is.
"""
import argparse, html, math, statistics, time
from datetime import datetime
from pathlib import Path
from netbot_common import load_config, p, read_samples
from dish_constants import DISH_DATA_KEY
from evaluate_alerts import tiles, NET_KEY, CRIT_DISH_ALERTS, WARN_DISH_ALERTS
import theme_tokens as TH
import ui_text as T

E = html.escape
DAY, WEEK = 86400, 7 * 86400

# ---------------------------------------------------------------- data
def series(samples, key, scale=1.0, sub=DISH_DATA_KEY):
    return [(s["ts"], s[sub][key] * scale) for s in samples
            if isinstance(s.get(sub), dict) and isinstance(s[sub].get(key), (int, float))]

def hourly(points):
    b = {}
    for t, v in points:
        b.setdefault(int(t // 3600) * 3600, []).append(v)
    return [(t, statistics.median(v)) for t, v in sorted(b.items())]

def charts(samples, now, router_on):
    """Chart rows: (section label, source mark, [(title, metric, points, unit, span seconds)])."""
    d1 = [s for s in samples if s["ts"] >= now - DAY]
    d7 = [s for s in samples if s["ts"] >= now - WEEK]
    rows = [
        (T.SECTION_DISH_24H, T.SRC_DISH, [
            (T.CHART_DISH_LATENCY, "latency", series(d1, "pop_ping_latency_ms"), "ms", DAY),
            (T.CHART_DISH_DROP, "ping-drop", series(d1, "pop_ping_drop_rate", 100), "%", DAY),
            (T.CHART_DISH_THROUGHPUT, "throughput", series(d1, "downlink_bps", 1e-6), "Mbps", DAY)]),
        (T.SECTION_DISH_7D, T.SRC_DISH_CALC, [
            (T.CHART_DISH_LATENCY_7D, "latency", hourly(series(d7, "pop_ping_latency_ms")), "ms", WEEK),
            (T.CHART_DISH_DROP_7D, "ping-drop", hourly(series(d7, "pop_ping_drop_rate", 100)), "%", WEEK),
            (T.CHART_DISH_THROUGHPUT_7D, "throughput", hourly(series(d7, "downlink_bps", 1e-6)), "Mbps", WEEK),
            (T.CHART_DISH_OBSTRUCTED_7D, "obstruction", hourly(series(d7, "fraction_obstructed", 100)), "%", WEEK)]),
        (T.SECTION_NETWORK_24H, T.SRC_CALC, [
            (T.CHART_GATEWAY_PING, "gateway-ping", series(d1, "gateway_ping_ms", sub=NET_KEY), "ms", DAY),
            (T.CHART_INTERNET_LATENCY, "internet-latency", series(d1, "internet_latency_ms", sub=NET_KEY), "ms", DAY),
            (T.CHART_PACKET_LOSS, "packet-loss", series(d1, "internet_loss", 100, sub=NET_KEY), "%", DAY),
            # speed tests run every few hours, so this one chart shows 7 days
            (T.CHART_SPEED_TEST, "speed-test", series(d7, "speedtest_down_mbps", sub=NET_KEY), "Mbps", WEEK)]),
    ]
    if router_on:
        rows.append((T.SECTION_ROUTER, T.SRC_ROUTER, [
            (T.CHART_ROUTER_DEVICES, "router-devices", series(d1, "client_count", sub="router"), "count", DAY)]))
    return rows

def _last(samples, sub, key):
    for s in reversed(samples):
        v = (s.get(sub) or {}).get(key) if isinstance(s.get(sub), dict) else None
        if v is not None:
            return v
    return None

def _med(points):
    return statistics.median(v for _, v in points) if points else None

def format_throughput_mbps(mbps):
    """Big numeral for the throughput tile.

    One decimal below 10 Mbps (0.2, 9.7). Whole numbers at 10 and above.
    A value above zero that would show as 0.0 is "<0.1". Exactly 0 is "0".
    """
    if mbps == 0:
        return "0"
    if mbps > 0 and mbps < 0.05:
        return "<0.1"
    if mbps < 10:
        return f"{mbps:.1f}"
    return f"{mbps:.0f}"


def readout_values(samples, now):
    """{tile name: (numeral or state word, unit, is_word, metric, source mark)}. Numbers use the tiles' own math."""
    hour = [s for s in samples if s["ts"] >= now - 3600]
    week = [s for s in samples if s["ts"] >= now - WEEK]
    last = samples[-1] if samples else {}
    d = last.get(DISH_DATA_KEY) or {}
    nodata = T.NO_DATA.upper()
    def num(v, fmt, unit, metric, src):
        if isinstance(v, (int, float)):
            text = fmt(v) if callable(fmt) else fmt.format(v)
            return (text, unit, False, metric, src)
        return (nodata, "", True, metric, src)
    def word(w, src=T.SRC_DISH):
        return (w, "", True, None, src)
    loss = [v for _, v in series(hour, "internet_loss", 100, sub=NET_KEY)]
    down = d.get("downlink_bps")
    ob = d.get("fraction_obstructed")
    state = (d.get("state") or nodata) if d.get("reachable") else ("UNREACHABLE" if last else nodata)
    firmware = "UPDATE PENDING" if d.get("update_pending") else (d.get("software_version") or nodata)[:22]
    return {
        T.TILE_DISH_STATUS: word(state),
        T.TILE_DISH_THROUGHPUT: num(down / 1e6 if isinstance(down, (int, float)) else None, format_throughput_mbps, "Mbps", "throughput", T.SRC_DISH),
        # the 1-hour median is NetBot's own calculation from dish values
        T.TILE_DISH_LATENCY: num(_med(series(hour, "pop_ping_latency_ms")), "{:.0f}", "ms", "latency", T.SRC_DISH_CALC),
        T.TILE_DISH_OBSTRUCTION: num(ob * 100 if isinstance(ob, (int, float)) else None, "{:.2f}", "%", "obstruction", T.SRC_DISH),
        T.TILE_DISH_ALERTS: num(len(d.get("alerts") or []) if last else None, "{}", "active", None, T.SRC_DISH),
        T.TILE_DISH_FIRMWARE: word(firmware),
        T.TILE_GATEWAY_PING: num(_last(hour, NET_KEY, "gateway_ping_ms"), "{:.1f}", "ms", "gateway-ping", T.SRC_CALC),
        T.TILE_INTERNET_LATENCY: num(_med(series(hour, "internet_latency_ms", sub=NET_KEY)), "{:.0f}", "ms", "internet-latency", T.SRC_CALC),
        T.TILE_PACKET_LOSS: num(statistics.mean(loss) if loss else None, "{:.1f}", "%", "packet-loss", T.SRC_CALC),
        T.TILE_SPEED_TEST: num(_med(series(week, "speedtest_down_mbps", sub=NET_KEY)), "{:.0f}", "Mbps", "speed-test", T.SRC_CALC),
    }

# ---------------------------------------------------------------- HTML
def status_pill(level):
    _, cls, word, _ = TH.LEVELS[level]
    return f'<span class="nb-status nb-st-{cls}"><span class="nb-light" aria-hidden="true"></span>{word}</span>'

def src_mark(src):
    return f'<span class="nb-src{"" if src in (T.SRC_DISH, T.SRC_ROUTER) else " nb-src--calc"}">{E(src)}</span>'

def readout(name, level, text, value, wide=False, extra=""):
    val, unit, is_word, metric, src = value
    key = '<span class="nb-key" aria-hidden="true"></span>' if metric else ""
    cls = f"nb-readout nb-st-{TH.LEVELS[level][1]}" + (f" nb-m-{metric}" if metric else "") + (" nb-readout--wide-3" if wide else "")
    numeral = (f'<span class="nb-num nb-num--word">{E(val)}</span>' if is_word else
               f'<span class="nb-num">{E(val)}</span><span class="nb-unit">{E(unit)}</span>')
    return (f'<article class="{cls}"><div class="nb-readout__head"><span class="nb-label">{key}{E(name)}</span>{status_pill(level)}</div>'
            f'<div class="nb-readout__value">{numeral}</div><p class="nb-readout__detail">{E(str(text))}</p>{extra}'
            f'<div class="nb-readout__foot">{src_mark(src)}</div></article>')

def system_tile(name, level, text):
    return (f'<div class="nb-system nb-st-{TH.LEVELS[level][1]}"><span class="nb-system__name">{E(name)}</span>{status_pill(level)}'
            f'<span class="nb-system__text">{E(str(text))}</span></div>')

def watch_list(active):
    items = sorted(CRIT_DISH_ALERTS) + sorted(WARN_DISH_ALERTS)
    li = "".join(f'<li class="{"nb-watch--on" if a in active else ""}"><span>{E(a.replace("_", " "))}</span><em>{"ALERT" if a in CRIT_DISH_ALERTS else "WARN"}</em></li>'
                 for a in items)
    return f'<ul class="nb-watch">{li}</ul>'

def svg_chart(points, t0, t1, unit, w=520, h=150):
    """Inline SVG with a responsive viewBox; colors come from the nb-chart-* classes and the figure's nb-m-* metric."""
    if not points:
        return f'<svg viewBox="0 0 {w} {h}" role="img"><text class="nb-chart-empty" x="{w/2}" y="{h/2}" text-anchor="middle">{T.NO_DATA}</text></svg>'
    left, right, top, bottom = 40, 6, 8, 18
    vmax = max(v for _, v in points) * 1.1 or 1
    span = (t1 - t0) or 1
    X = lambda t: left + (t - t0) / span * (w - left - right)
    Y = lambda v: top + (1 - v / vmax) * (h - top - bottom)
    grid = "".join(f'<line class="nb-chart-gridline" x1="{left}" x2="{w-right}" y1="{Y(vmax*q/4):.1f}" y2="{Y(vmax*q/4):.1f}"/>' for q in (1, 2, 3, 4))
    step = 6 * 3600 if span <= DAY else DAY
    first = math.ceil(t0 / step) * step
    vgrid = "".join(f'<line class="nb-chart-gridline" x1="{X(t):.1f}" x2="{X(t):.1f}" y1="{top}" y2="{h-bottom}"/>'
                    f'<text class="nb-chart-tick" x="{X(t):.1f}" y="{h-4}" text-anchor="middle">'
                    f'{datetime.fromtimestamp(t).strftime("%H:%M" if step < 86400 else "%a")}</text>'
                    for t in range(int(first), int(t1) + 1, step))
    xy = " ".join(f"{X(t):.1f},{Y(v):.1f}" for t, v in points)
    area = f"{X(points[0][0]):.1f},{Y(0):.1f} {xy} {X(points[-1][0]):.1f},{Y(0):.1f}"
    return (f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="{E(unit)}">{grid}{vgrid}'
            f'<line class="nb-chart-axis" x1="{left}" x2="{w-right}" y1="{Y(0):.1f}" y2="{Y(0):.1f}"/>'
            f'<polygon class="nb-chart-area" points="{area}"/><polyline class="nb-chart-line" points="{xy}"/>'
            f'<text class="nb-chart-tick" x="{left-4}" y="{top+8}" text-anchor="end">{vmax:.0f}</text>'
            f'<text class="nb-chart-tick" x="{left-4}" y="{Y(0):.1f}" text-anchor="end">0</text></svg>')

# Header line art (STYLE-SPEC section 8), drawn with theme classes and variables only.
HEADER_ART = ('<svg class="nb-header__art" viewBox="0 0 800 200" preserveAspectRatio="xMaxYMid slice" fill="none" aria-hidden="true">'
              '<g class="nb-orbit nb-orbit--faint" stroke-width="1"><ellipse cx="640" cy="120" rx="300" ry="64" transform="rotate(-14 640 120)"/>'
              '<ellipse cx="640" cy="120" rx="210" ry="44" transform="rotate(-14 640 120)"/><circle cx="640" cy="120" r="34"/></g>'
              '<g class="nb-orbit" stroke-width="1.25" stroke-linecap="round"><path d="M352 168 A300 64 -14 0 1 912 18" opacity=".55"/>'
              '<path d="M444 150 A210 44 -14 0 1 820 52" stroke-dasharray="2 6" opacity=".8"/>'
              '<path d="M60 196 C 260 150, 420 70, 800 4" stroke-dasharray="1 5" opacity=".35"/></g>'
              '<rect class="nb-orbit" x="248.5" y="142.5" width="7" height="7" stroke-width="1.5" style="fill: var(--nb-bg)"/></svg>')

def build_html(samples, now, example=False, title=T.PRODUCT_TITLE):
    t = tiles(samples, now)
    vals = readout_values(samples, now)
    last = samples[-1] if samples else {}
    router_on = isinstance(last.get("router"), dict)
    active = set((last.get(DISH_DATA_KEY) or {}).get("alerts") or [])
    def panels(names, wide=()):
        return "".join(readout(n, *t[n], vals[n], wide=n in wide, extra=watch_list(active) if n == T.TILE_DISH_ALERTS else "")
                       for n in names if n in t)
    dish = [T.TILE_DISH_STATUS, T.TILE_DISH_THROUGHPUT, T.TILE_DISH_LATENCY, T.TILE_DISH_OBSTRUCTION, T.TILE_DISH_FIRMWARE, T.TILE_DISH_ALERTS]
    net = [T.TILE_GATEWAY_PING, T.TILE_INTERNET_LATENCY, T.TILE_PACKET_LOSS, T.TILE_SPEED_TEST]
    collector = system_tile(T.TILE_COLLECTOR, *t[T.TILE_COLLECTOR]) if T.TILE_COLLECTOR in t else ""
    banner = (f'<div class="nb-banner" role="note"><span aria-hidden="true">\u25B2</span>{E(T.EXAMPLE_BANNER)}</div>' if example else "")
    chips = "".join(f'<span class="nb-chip{" nb-chip--on" if on else ""}">{E(c)}</span>' for c, on in
                    ((T.CHIP_DISH, True), (T.CHIP_NETWORK, True), (T.CHIP_ROUTER.format(state="on" if router_on else "off"), router_on)))
    legend = "".join(f'<li>{src_mark(m)}{E(d)}</li>' for m, d in T.LEGEND)
    def chart_grid(src, items):
        size = {"w": 1300, "h": 220} if len(items) == 1 else {}   # full-width chart: wider viewBox, same tick size
        figs = "".join(f'<div class="nb-chart nb-m-{m}" role="group" aria-label="{E(n)}"><div class="nb-chart__head"><span class="nb-chart__title">'
                       f'<span class="nb-key" aria-hidden="true"></span>{E(n)}</span>{src_mark(src)}</div>'
                       f'{svg_chart(pts, now - span, now, u, **size)}</div>' for n, m, pts, u, span in items)
        return f'<div class="nb-charts{ {1: " nb-charts--1", 4: " nb-charts--4"}.get(len(items), "") }">{figs}</div>'
    def chart_section(label, src, items):
        return f'<section class="nb-section"><h2 class="nb-section__label">{E(label)}</h2>{chart_grid(src, items)}</section>'
    rows = charts(samples, now, router_on)
    router = ""
    if router_on:   # add-on section: left out of the HTML entirely when the add-on is off
        _, src, items = rows.pop()
        router = (f'<section class="nb-addon"><h2 class="nb-section__label">{E(T.SECTION_ROUTER)} <span class="nb-tag">ADD-ON</span></h2>'
                  f'<div class="nb-systems">{system_tile(T.TILE_ROUTER, *t[T.TILE_ROUTER])}</div>{chart_grid(src, items)}</section>')
    when = datetime.fromtimestamp(now).strftime("%a %b %d, %I:%M %p")
    heading = title.split(": ", 1)[-1]
    offline = (
        '<div class="nb-statebar nb-statebar--offline" role="note">'
        '<span class="nb-statebar__mark" aria-hidden="true"></span>'
        f'<p><b>Offline copy · snapshot from {E(when)} · not live</b>'
        '<span class="nb-statebar__sub">A saved copy of the dashboard. Values do not update, '
        'and the live link isn\'t included.</span></p></div>'
    )
    clock = f'<p class="nb-clock">Snapshot<b>{E(when)}</b></p>'
    foot = "Offline copy · not live"
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="300">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{E(title)}</title>
<style>{TH.inline_css()}</style></head><body class="nb-page"><main class="nb-wrap">
{banner}{offline}<header class="nb-header">{HEADER_ART}<div><h1 class="nb-title" aria-label="{E(title)}"><span class="nb-brand">{E(T.APP_NAME)}</span><span class="nb-title__name">{E(heading)}</span></h1>
<div class="nb-chips">{chips}</div></div>{clock}</header>
<ul class="nb-legend">{legend}</ul>
<section class="nb-section"><h2 class="nb-section__label">{E(T.SECTION_DISH)}</h2>{('<div class="nb-systems">' + collector + '</div>') if collector else ''}
<div class="nb-readouts">{panels(dish, wide=(T.TILE_DISH_ALERTS,))}</div></section>
<section class="nb-section"><h2 class="nb-section__label">{E(T.SECTION_NETWORK)}</h2><div class="nb-readouts">{panels(net)}</div></section>
{"".join(chart_section(*r) for r in rows)}
{router}
<footer class="nb-footer"><span>{E(T.APP_NAME)}</span><span>{E(foot)}</span></footer>
</main></body></html>"""

# ---------------------------------------------------------------- PNG
TILE_COLS = 4

def png_layout(n_tiles, chart_rows):
    """Figure height (inches) and axes rectangles [x, y, w, h] in figure fractions, computed from the tile count so
    tiles never overlap the charts (any count; 12 or 13 tiles give 3 or 4 rows). Returns (height, tiles, charts)."""
    width, head, tile_h, tile_gap, chart_h, chart_gap, foot = 14.0, 1.1, 0.62, 0.12, 2.2, 0.9, 0.4
    tile_rows = max(1, math.ceil(n_tiles / TILE_COLS))
    height = head + tile_rows * (tile_h + tile_gap) + len(chart_rows) * (chart_h + chart_gap) + foot
    f = lambda inches: inches / height
    tiles_r, y = [], height - head
    for i in range(n_tiles):
        r, c = divmod(i, TILE_COLS)
        top = y - r * (tile_h + tile_gap)
        tiles_r.append([0.02 + c * 0.245, f(top - tile_h), 0.235, f(tile_h)])
    y -= tile_rows * (tile_h + tile_gap)
    charts_r = []
    for n in chart_rows:
        y -= chart_gap
        w = 0.90 / n
        charts_r.append([[0.05 + c * w, f(y - chart_h), w - 0.045, f(chart_h)] for c in range(n)])
        y -= chart_h
    return height, tiles_r, charts_r

def build_png(samples, now, path, example=False, title=T.PRODUCT_TITLE):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    C = TH.mpl_colors()
    plt.style.use(str(TH.MPLSTYLE))
    t = tiles(samples, now)
    last = samples[-1] if samples else {}
    router_on = isinstance(last.get("router"), dict)
    if not router_on:
        t.pop(T.TILE_ROUTER, None)   # add-on off: left out, as in the HTML
    rows = charts(samples, now, router_on)
    height, tile_rects, chart_rects = png_layout(len(t), [len(items) for _, _, items in rows])
    fig = plt.figure(figsize=(14, height), dpi=100)
    fig.suptitle(title, fontsize=16, fontweight="semibold", color=C["text"], y=1 - 0.30 / height)
    sub = datetime.fromtimestamp(now).strftime("Snapshot %a %b %d %Y, %I:%M %p")
    fig.text(0.5, 1 - 0.66 / height, sub + (f"   {T.EXAMPLE_MARK}" if example else ""), ha="center", va="top", fontsize=10,
             color=C["status"]["yellow"] if example else C["text3"])
    for rect, (k, (lvl, txt)) in zip(tile_rects, t.items()):
        ax = fig.add_axes(rect)
        ax.set_xticks([]); ax.set_yticks([]); ax.grid(False)
        ax.set_facecolor(C["panel"])
        for s in ax.spines.values():
            s.set_visible(True); s.set_color(C["hair"])
        col, word, mark = C["status"][lvl], TH.LEVELS[lvl][2], TH.LEVELS[lvl][3]
        ax.add_patch(plt.Rectangle((0, 0), 0.018, 1, color=col, transform=ax.transAxes))   # status bar + mark + word
        ax.text(0.05, 0.64, k, fontsize=10, fontweight="semibold", color=C["text"], transform=ax.transAxes)
        ax.text(0.97, 0.64, f"{mark} {word}", fontsize=8.5, fontweight="bold", color=col, ha="right", transform=ax.transAxes)
        ax.text(0.05, 0.22, str(txt)[:48], fontsize=8.5, color=C["text2"], transform=ax.transAxes)
    for rects, (label, src, items) in zip(chart_rects, rows):
        x0, top = rects[0][0], rects[0][1] + rects[0][3]
        fig.text(x0, top + 0.40 / height, f"{label.upper()}   [{src}]", fontsize=8, fontweight="bold", color=C["text2"])
        for rect, (lbl, metric, pts, unit, span) in zip(rects, items):
            ax = fig.add_axes(rect)
            col = C["metric"][metric]
            if pts:
                xs, ys = [datetime.fromtimestamp(x) for x, _ in pts], [v for _, v in pts]
                ax.plot(xs, ys, color=col)
                ax.fill_between(xs, ys, color=col, alpha=C["fill_alpha"], lw=0)
            else:
                ax.text(0.5, 0.5, T.NO_DATA, ha="center", va="center", color=C["text3"], transform=ax.transAxes)
            ax.set_title(lbl, fontsize=9)
            if span <= DAY:
                ax.xaxis.set_major_locator(mdates.HourLocator(byhour=range(0, 24, 6)))
                ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
            else:
                ax.xaxis.set_major_locator(mdates.DayLocator())
                ax.xaxis.set_major_formatter(mdates.DateFormatter("%a"))
    if example:
        fig.text(0.5, 0.5, T.EXAMPLE_MARK, fontsize=80, color=C["status"]["yellow"], alpha=0.06, ha="center", va="center", rotation=20)
    fig.savefig(path)
    plt.close(fig)

# ---------------------------------------------------------------- run
def run(cfg=None, png=None, example=False, now=None, title=T.PRODUCT_TITLE):
    cfg = cfg or load_config()
    now = now or time.time()
    data_dir = p(cfg["paths"]["data_dir"])
    samples = read_samples(data_dir, now - WEEK)
    out_dir = data_dir.parent / "dashboard"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "index.html").write_text(build_html(samples, now, example, title), encoding="utf-8")
    sync = p(cfg["paths"].get("sync_dir"))
    png = Path(png) if png else ((sync or out_dir) / "dashboard.png")
    try:
        build_png(samples, now, png, example, title)
    except ImportError:
        pass  # matplotlib not installed: HTML only
    return out_dir / "index.html", png

if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("--example", action="store_true")
    a.add_argument("--png")
    a.add_argument("--title", default=T.PRODUCT_TITLE, help="dashboard title (default: the product title)")
    args = a.parse_args()
    print(run(png=args.png, example=args.example, title=args.title))
