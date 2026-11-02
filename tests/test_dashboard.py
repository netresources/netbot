#!/usr/bin/env python3
"""Dashboard theme and layout tests (stdlib unittest; matplotlib not needed).

- No color value (hex, rgb()/hsl(), FromArgb(n, ...)) in any shipped file outside netbot/theme/.
- The theme files are internally consistent, and match the design folder when one is present
  (./_design, or NETBOT_DESIGN_DIR). The design folder is not on the branch, so those checks skip in a clean clone.
- The HTML uses only theme classes and variables; every status shows its shape and word (OK = dot + "OK").
- The PNG tile grid never overlaps the charts, for any tile count.
Run:  python3 tests/test_dashboard.py
"""
import hashlib, os, re, sys, tempfile, time, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "netbot"))
import theme_tokens as TH   # noqa: E402
import ui_text as T         # noqa: E402

THEME_DIR = "netbot/theme"
# Test fixtures: verbatim copies of the Windows dialog design files, which Pester checks. They are the one other
# place color values may appear, and their colors must be shipped theme tokens (checked below and by Pester).
FIXTURE_DIR = "tests/windows/fixtures"
SKIP_DIRS = {".git", "_design", "_review", "__pycache__", ".venv", ".venv-test"}
COLOR_LITERAL = re.compile(r"(?<![&\w])#(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3,4})\b|\b(?:rgba?|hsla?)\(\s*\d|FromArgb\(\s*\d")

def uplot_pin():
    """The one sha256 pin from the anonymity scan. Shared so both checks exempt the same bytes."""
    text = (ROOT / "tests/check_anonymous.sh").read_text(encoding="utf-8")
    path = re.search(r'^UPLOT_PIN_PATH = "([^"]+)"', text, re.M).group(1)
    digest = re.search(r'^UPLOT_PIN_SHA256 = "([0-9a-f]{64})"', text, re.M).group(1)
    return path, digest
DESIGN = Path(os.environ.get("NETBOT_DESIGN_DIR") or ROOT / "_design")
HAVE_DESIGN = (DESIGN / "tokens.css").is_file()

def color_literals(root):
    """[(relative path, line number, text)] for every color literal outside netbot/theme/.

    The vendored chart file is skipped only when its sha256 matches the anonymity-scan pin.
    A modified copy is scanned, and its own color literals fail the check.
    """
    pin_path, pin_sha = uplot_pin()
    hits = []
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        rel_dir = Path(dirpath).relative_to(root).as_posix()
        if any(rel_dir == d or rel_dir.startswith(d + "/") for d in (THEME_DIR, FIXTURE_DIR)):
            continue
        for f in files:
            path = Path(dirpath) / f
            rel = path.relative_to(root).as_posix()
            if rel == pin_path:
                try:
                    if hashlib.sha256(path.read_bytes()).hexdigest() == pin_sha:
                        continue
                except OSError:
                    pass
            try:
                text = path.read_text()
            except (UnicodeDecodeError, OSError):
                continue   # binaries
            for n, line in enumerate(text.splitlines(), 1):
                if COLOR_LITERAL.search(line):
                    hits.append((path.relative_to(root).as_posix(), n, line.strip()))
    return hits

def mock_samples(now, router=True):
    import mock_data
    from netbot_common import read_samples
    d = Path(tempfile.mkdtemp()) / "data"
    mock_data.main(str(d), now)
    s = read_samples(d, now - 7 * 86400)
    if not router:
        for x in s:
            x.pop("router", None)
    return s

NOW = time.mktime((2026, 10, 19, 6, 45, 0, 0, 0, -1))


class TextFilesAreUtf8(unittest.TestCase):
    """Windows' default text encoding is not UTF-8, so every text read/write in netbot/ names it (the dashboard has non-ASCII marks)."""
    def test_explicit_encoding(self):
        bad = []
        for f in sorted((ROOT / "netbot").glob("*.py")):
            for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                if re.search(r"\.(read|write)_text\(|\bopen\(", line) and "encoding=" not in line and not re.search(r"open\([^)]*\"[rwa]b\"|urlopen|tarfile\.open", line):
                    bad.append(f"{f.name}:{n}: {line.strip()}")
        self.assertEqual(bad, [])

class NoColorOutsideTheme(unittest.TestCase):
    def test_package_has_no_color_literals_outside_theme(self):
        hits = color_literals(ROOT)
        self.assertEqual(hits, [], "color values belong in netbot/theme/ only:\n" + "\n".join(f"{p}:{n}: {t}" for p, n, t in hits))

    def test_checker_catches_a_planted_value(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "netbot" / "theme").mkdir(parents=True)
            h, a = "#", "FromArgb("   # planted values are assembled here so this file itself stays clean
            (Path(d) / "netbot" / "theme" / "ok.css").write_text("a { color: " + h + "3DF26F }\n")   # allowed: theme file
            (Path(d) / "netbot" / "x.py").write_text('C = "' + h + '2e9e44"\n')
            (Path(d) / "y.ps1").write_text("$c = [Drawing.Color]::" + a + "6, 8, 11)\n")
            (Path(d) / "z.html").write_text('<i style="color: ' + 'rgb(' + '1, 2, 3)">\n')
            (Path(d) / "w.sh").write_text('n=${#items[@]}  # issue #12 and &#9650; are not colors\n')
            pin_path, pin_sha = uplot_pin()
            real = (ROOT / pin_path).read_bytes()
            self.assertEqual(hashlib.sha256(real).hexdigest(), pin_sha)
            pinned = Path(d) / pin_path
            pinned.parent.mkdir(parents=True)
            pinned.write_bytes(real)
            self.assertEqual(sorted(p for p, _, _ in color_literals(Path(d))), ["netbot/x.py", "y.ps1", "z.html"])
            flipped = bytearray(real)
            flipped[10] ^= 0x01
            pinned.write_bytes(bytes(flipped))
            self.assertIn(pin_path, [p for p, _, _ in color_literals(Path(d))])

    def test_fixture_colors_are_theme_tokens(self):
        tokens = {v.upper() for v in TH.css_vars().values() if re.fullmatch(r"#[0-9A-Fa-f]{6}", v)}
        spec = (ROOT / FIXTURE_DIR / "WINDOWS-DIALOGS.md").read_text()
        hover = {m.upper() for m in re.findall(r"(?im)^\|\s*Accent hover\s*\|\s*`(#[0-9A-F]{6})`", spec)}
        self.assertEqual(len(hover), 1, "the spec names exactly one non-token shade (accent hover)")
        for f in ("windows-dialog-sample.ps1", "WINDOWS-DIALOGS.md"):
            used = {h.upper() for h in re.findall(r"(?<![&\w])#[0-9A-Fa-f]{6}\b", (ROOT / FIXTURE_DIR / f).read_text())}
            self.assertTrue(used)
            self.assertEqual(used - tokens - hover, set(), f"{FIXTURE_DIR}/{f} uses colors that are not theme tokens")

    def test_dashboard_code_names_no_colors(self):
        src = (ROOT / "netbot" / "make_dashboard.py").read_text()
        self.assertIsNone(re.search(r"""color\s*=\s*["']""", src), "matplotlib colors must come from theme_tokens")
        self.assertNotRegex(src, r"""style="[^"]*(?:color|background)\s*:\s*(?!var\()""")

    def test_live_css_colors_are_tokens_or_the_accent_hover(self):
        tokens = {v.upper() for v in TH.css_vars().values() if re.fullmatch(r"#[0-9A-Fa-f]{6}", v)}
        shade = "#" + "8AF7A4"   # accent hover, assembled so this line is not itself a color literal
        hover = {shade}
        css = (ROOT / THEME_DIR / "netbot-live.css").read_text(encoding="utf-8")
        used = {h.upper() for h in re.findall(r"(?<![&\w])#[0-9A-Fa-f]{3,8}\b", css)}
        self.assertEqual(used - tokens - hover, set(), "live CSS colors must be theme tokens or the accent hover")
        for rel in ("netbot/live_page/live.js", "netbot/live_page/index.html", "netbot/live_server.py", "netbot/live_data.py"):
            self.assertIsNone(COLOR_LITERAL.search((ROOT / rel).read_text(encoding="utf-8")), rel)

class ThemeFiles(unittest.TestCase):
    def test_tokens_parse(self):
        c = TH.mpl_colors()
        self.assertEqual(set(c["metric"]), set(TH.METRIC_NAMES))
        self.assertEqual(set(c["status"]), {"green", "yellow", "red", "gray"})
        self.assertNotIn(c["accent"].lower(), {v.lower() for v in c["metric"].values()} | {v.lower() for v in c["status"].values()},
                         "the accent is not a data or status color")

    def test_mplstyle_uses_token_colors_in_metric_order(self):
        tokens = {v.strip("#").lower() for v in TH.css_vars().values() if re.fullmatch(r"#[0-9A-Fa-f]{6}", v)}
        style = re.sub(r"#.*", "", TH.MPLSTYLE.read_text())
        used = {h.lower() for h in re.findall(r"\b[0-9A-Fa-f]{6}\b", style)}
        self.assertTrue(used and used <= tokens, f"mplstyle colors not in tokens.css: {sorted(used - tokens)}")
        cycle = re.search(r"axes\.prop_cycle:.*", style).group(0)
        metric = TH.mpl_colors()["metric"]
        self.assertEqual([h.lower() for h in re.findall(r"[0-9A-Fa-f]{6}", cycle)],
                         [metric[n].strip("#").lower() for n in TH.METRIC_NAMES])

    def test_theme_css_classes_cover_every_metric_and_level(self):
        css = TH.THEME_CSS.read_text()
        for n in TH.METRIC_NAMES:
            self.assertIn(f".nb-m-{n}", css)
        for _, cls, _, _ in TH.LEVELS.values():
            self.assertIn(f".nb-st-{cls}", css)

    @unittest.skipUnless(HAVE_DESIGN, "no design folder (clean clone); set NETBOT_DESIGN_DIR to compare")
    def test_shipped_copies_match_design(self):
        for f in ("tokens.css", "netbot-theme.css", "netbot-dark.mplstyle"):
            self.assertEqual((ROOT / THEME_DIR / f).read_bytes(), (DESIGN / f).read_bytes(), f"{THEME_DIR}/{f} differs from the design copy")

    @unittest.skipUnless(HAVE_DESIGN and (DESIGN / "mpl_rcparams_snippet.py").is_file(), "no design folder")
    def test_metric_map_matches_design_snippet(self):
        snip = (DESIGN / "mpl_rcparams_snippet.py").read_text()
        block = snip[snip.index("METRIC = {"):]
        block = block[:block.index("}")]
        want = {k: v.lower() for k, v in re.findall(r'"([\w-]+)":\s*"(#[0-9A-Fa-f]{6})"', block)}
        got = {k: v.lower() for k, v in TH.mpl_colors()["metric"].items()}
        self.assertEqual(got, want)
        status = dict(re.findall(r'"(\w+)": "(#[0-9A-Fa-f]{6})"', snip[snip.index("STATUS = {"):snip.index("STATUS_WORD")]))
        self.assertEqual({k: v.lower() for k, v in TH.mpl_colors()["status"].items()}, {k: v.lower() for k, v in status.items()})

class Html(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import make_dashboard as M
        cls.M = M
        cls.html = M.build_html(mock_samples(NOW), NOW, example=True)
        cls.html_core = M.build_html(mock_samples(NOW, router=False), NOW)
        cls.body = re.sub(r"<style>.*?</style>", "", cls.html, flags=re.S)

    def test_title_and_header(self):
        self.assertIn(f"<title>{T.PRODUCT_TITLE}</title>", self.html)
        self.assertIn(f'<h1 class="nb-title" aria-label="{T.PRODUCT_TITLE}">', self.html)
        self.assertIn(f'<span class="nb-brand">{T.APP_NAME}</span>', self.html)
        self.assertIn('<span class="nb-title__name">Connection Monitor</span>', self.html)
        self.assertEqual(self.html.count("<h1"), 1)

    def test_no_color_values_outside_the_inlined_theme(self):
        self.assertIsNone(COLOR_LITERAL.search(self.body))
        self.assertIn(TH.TOKENS_CSS.read_text(), self.html)   # theme inlined verbatim: no external requests
        self.assertNotRegex(self.body, r"""(?:href|src)=["']https?:""")

    def test_every_status_has_shape_and_word(self):
        pills = re.findall(r'<span class="nb-status nb-st-(\w+)"><span class="nb-light" aria-hidden="true"></span>([A-Z ]+)</span>', self.body)
        self.assertEqual(len(pills), self.body.count('class="nb-status'))
        words = {cls: word for _, cls, word, _ in TH.LEVELS.values()}
        self.assertTrue(pills)
        for cls, word in pills:
            self.assertEqual(word, words[cls])
        self.assertIn(("ok", "OK"), pills)

    def test_dish_charts_and_network_row(self):
        titles = re.findall(r'<span class="nb-chart__title"><span class="nb-key" aria-hidden="true"></span>([^<]+)</span>', self.body)
        dish = [t for t in titles if t.startswith("Dish")]
        self.assertEqual(len(dish), 7)
        for t in (T.CHART_GATEWAY_PING, T.CHART_INTERNET_LATENCY, T.CHART_PACKET_LOSS, T.CHART_SPEED_TEST):
            self.assertIn(t, titles)
        self.assertIn(T.SECTION_NETWORK_24H, self.body)
        for n in TH.METRIC_NAMES:
            self.assertIn(f'nb-chart nb-m-{n}"', self.body)

    def test_source_marks(self):
        """Each readout's source mark: values NetBot calculates (medians, means) are never tagged as the dish's own."""
        marks = dict(re.findall(r'<span class="nb-label">(?:<span class="nb-key" aria-hidden="true"></span>)?([^<]+)</span>.*?'
                                r'<div class="nb-readout__foot"><span class="nb-src[^"]*">([^<]+)</span>', self.body))
        want = {T.TILE_DISH_STATUS: T.SRC_DISH, T.TILE_DISH_THROUGHPUT: T.SRC_DISH, T.TILE_DISH_LATENCY: T.SRC_DISH_CALC,
                T.TILE_DISH_OBSTRUCTION: T.SRC_DISH, T.TILE_DISH_FIRMWARE: T.SRC_DISH, T.TILE_DISH_ALERTS: T.SRC_DISH,
                T.TILE_GATEWAY_PING: T.SRC_CALC, T.TILE_INTERNET_LATENCY: T.SRC_CALC, T.TILE_PACKET_LOSS: T.SRC_CALC,
                T.TILE_SPEED_TEST: T.SRC_CALC}
        self.assertEqual({k: marks.get(k) for k in want}, want)
        self.assertIn('<span class="nb-src nb-src--calc">DISH · CALC</span>', self.body)

    def test_router_section_only_with_add_on(self):
        self.assertIn('class="nb-addon"', self.html)
        self.assertNotIn('class="nb-addon"', self.html_core)
        self.assertNotIn(T.CHART_ROUTER_DEVICES, self.html_core)

    def test_title_argument(self):
        page = self.M.build_html([], NOW, title="Other")
        self.assertIn("<title>Other</title>", page)
        self.assertIn('aria-label="Other"', page)
        self.assertIn(f'<span class="nb-brand">{T.APP_NAME}</span>', page)
        self.assertIn('<span class="nb-title__name">Other</span>', page)

    def test_offline_copy_banner_and_omitted_live_parts(self):
        for page in (self.html, self.html_core):
            self.assertIn('class="nb-statebar nb-statebar--offline"', page)
            self.assertIn('role="note"', page)
            self.assertIn("Offline copy · snapshot from", page)
            self.assertIn("· not live", page)
            self.assertIn("A saved copy of the dashboard. Values do not update, and the live link isn't included.", page)
            self.assertIn(">Snapshot<", page)
            self.assertIn("Offline copy · not live", page)
            self.assertNotIn("nb-live", page)
            self.assertNotIn("nb-access", page)
            self.assertNotIn("Private link", page)
            self.assertNotIn("btn-copy", page)
            self.assertNotIn("btn-show", page)
            self.assertNotIn("?key=", page)
            self.assertNotIn("Works only on your home Wi-Fi", page)
        self.assertIn(T.EXAMPLE_BANNER, self.html)
        self.assertNotIn('class="nb-banner"', self.html_core)

    def test_throughput_tile_shows_a_decimal_below_10(self):
        from dish_constants import DISH_DATA_KEY
        fmt = self.M.format_throughput_mbps
        self.assertEqual(fmt(0), "0")
        self.assertEqual(fmt(0.0), "0")
        self.assertEqual(fmt(0.04), "<0.1")
        self.assertEqual(fmt(0.049), "<0.1")
        self.assertEqual(fmt(0.05), "0.1")
        self.assertEqual(fmt(0.2), "0.2")
        self.assertEqual(fmt(9.7), "9.7")
        self.assertEqual(fmt(10), "10")
        self.assertEqual(fmt(10.4), "10")
        self.assertEqual(fmt(252), "252")

        def numeral(bps):
            sample = {"ts": NOW, DISH_DATA_KEY: {
                "reachable": True, "state": "CONNECTED", "downlink_bps": bps, "alerts": []}}
            return self.M.readout_values([sample], NOW)[T.TILE_DISH_THROUGHPUT][0]

        self.assertEqual(numeral(200_000), "0.2")
        self.assertEqual(numeral(0), "0")
        self.assertEqual(numeral(20_000), "<0.1")
        self.assertEqual(numeral(9_700_000), "9.7")
        self.assertEqual(numeral(10_000_000), "10")
        page = self.M.build_html([{"ts": NOW, DISH_DATA_KEY: {
            "reachable": True, "state": "CONNECTED", "downlink_bps": 200_000, "alerts": []}}], NOW)
        self.assertRegex(page, r'nb-m-throughput[\s\S]*?<span class="nb-num">0\.2</span>')
        js = (ROOT / "netbot/live_page/live.js").read_text(encoding="utf-8")
        self.assertIn("function formatMbps(mbps)", js)
        self.assertIn('if (mbps === 0) return "0";', js)
        self.assertIn('if (mbps > 0 && mbps < 0.05) return "<0.1";', js)
        self.assertIn("if (mbps < 10) return mbps.toFixed(1);", js)
        self.assertIn("return mbps.toFixed(0);", js)
        self.assertIn('tile.metric === "throughput" ? throughputNumeral(tile.value)', js)

    def test_router_chart_labels_every_four_hours(self):
        js = (ROOT / "netbot/live_page/live.js").read_text(encoding="utf-8")
        self.assertIn('chart.metric === "router-devices"', js)
        self.assertIn("xAxis.incrs = [4 * 3600];", js)
        self.assertEqual(js.count("incrs"), 1)

    def test_charts_size_to_their_cards(self):
        js = (ROOT / "netbot/live_page/live.js").read_text(encoding="utf-8")
        css = (ROOT / "netbot/theme/netbot-live.css").read_text(encoding="utf-8")
        self.assertIn("new ResizeObserver", js)
        self.assertIn("u.setSize({width: w, height: CHART_H})", js)
        self.assertIn("requestAnimationFrame", js)
        self.assertNotIn("|| 640", js)
        self.assertNotIn("width = 640", js)
        self.assertIn(".nb-chart { min-width: 0; max-width: 100%; overflow: hidden; }", css)
        self.assertIn(".nb-plot { position: relative; width: 100%; min-width: 0; max-width: 100%;", css)
        self.assertIn(".nb-charts.nb-charts--1 { grid-template-columns: minmax(0, 1fr); }", css)
        self.assertRegex(css, r"\.uplot canvas \{[^}]*width:\s*100%;\s*height:\s*100%;")

    def test_empty_chart_is_exclusive(self):
        js = (ROOT / "netbot/live_page/live.js").read_text(encoding="utf-8")
        empty = js.split("function showEmpty", 1)[1].split("function resizePlot", 1)[0]
        self.assertIn('host.textContent = ""', empty)
        self.assertIn('nb-chart__empty", "no data"', empty)
        self.assertNotIn("uPlot", empty)
        mount = js.split("function mountChart", 1)[1].split("function renderAccess", 1)[0]
        self.assertIn("rows.length < 2", mount)
        self.assertIn("showEmpty(host)", mount)
        self.assertLess(mount.index("host.textContent = \"\""), mount.index("new window.uPlot"))
        self.assertLess(mount.index("new window.uPlot"), mount.rindex("showEmpty(host)"))

    def test_charts_have_no_hover_cursor(self):
        js = (ROOT / "netbot/live_page/live.js").read_text(encoding="utf-8")
        css = (ROOT / "netbot/theme/netbot-live.css").read_text(encoding="utf-8")
        self.assertIn("cursor: {show: false, drag: {x: false, y: false, setScale: false}}", js)
        self.assertIn("select: {show: false}", js)
        self.assertIn("points: {show: false}", js)
        self.assertIn(".u-cursor-x, .u-cursor-y, .u-cursor-pt", css)
        self.assertIn("display: none !important", css)

    def test_firmware_pending_sentence(self):
        from dish_constants import DISH_DATA_KEY
        import evaluate_alerts as ev
        sentence = "2026.10.02.mr60001 · update pending, installs ~3 AM"
        sample = {"ts": NOW, DISH_DATA_KEY: {
            "reachable": True, "software_version": "2026.10.02.mr60001", "update_pending": True, "alerts": []}}
        self.assertEqual(ev.tiles([sample], NOW)[T.TILE_DISH_FIRMWARE], ("yellow", sentence))
        self.assertIn(sentence, self.html)
        self.assertNotIn("(update pending", self.html)
        self.assertIn(">UPDATE PENDING<", self.html)

    def test_example_banner_follows_the_flag(self):
        import live_data
        page = (ROOT / "netbot/live_page/index.html").read_text(encoding="utf-8")
        js = (ROOT / "netbot/live_page/live.js").read_text(encoding="utf-8")
        self.assertRegex(page, r'id="example"[^>]*hidden')
        self.assertNotIn(T.EXAMPLE_BANNER, page)
        self.assertIn("status.example", js)
        samples = mock_samples(NOW)
        for row in samples:
            row.pop("example", None)
        off = live_data.build_status(samples, NOW, {"live": {}})
        self.assertFalse(off["example"])
        samples[-1]["example"] = True
        on = live_data.build_status(samples, NOW, {"live": {}})
        self.assertTrue(on["example"])
        self.assertEqual(on["example_text"], T.EXAMPLE_BANNER)
        for row in samples:
            row["example"] = False
        forced = live_data.build_status(samples, NOW, {"live": {"example": True}})
        self.assertTrue(forced["example"])

    def test_header_mark_sits_left_and_narrow_layout_is_one_column(self):
        self.assertIn('nb-cosmos', self.M.HEADER_ART)
        self.assertIn('nb-cosmos__canvas', self.M.HEADER_ART)
        self.assertNotIn('stop-color', self.M.HEADER_ART)
        css = (ROOT / "netbot/theme/netbot-theme.css").read_text(encoding="utf-8")
        self.assertIn("@media (max-width: 430px)", css)
        live = (ROOT / "netbot/theme/netbot-live.css").read_text(encoding="utf-8")
        self.assertIn('[data-live="lost"] .nb-chip', live)
        self.assertIn('[data-live="lost"] .nb-src--calc', live)

class PngLayout(unittest.TestCase):
    def check(self, n_tiles, rows):
        import make_dashboard as M
        h, tiles, charts = M.png_layout(n_tiles, rows)
        flat = [r for row in charts for r in row]
        self.assertEqual(len(tiles), n_tiles)
        for x, y, w, hh in tiles + flat:
            self.assertTrue(0 <= x and x + w <= 1 and 0 <= y and y + hh <= 1, (x, y, w, hh))
        lowest_tile = min(y for _, y, _, _ in tiles)
        highest_chart = max(y + hh for _, y, _, hh in flat)
        self.assertGreater(lowest_tile, highest_chart, "tiles overlap the charts")
        for a in tiles:
            for b in tiles:
                if a is not b:
                    self.assertFalse(a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3])

    def test_11_to_13_tiles(self):
        for n in (11, 12, 13):
            self.check(n, [3, 4, 4])
            self.check(n, [3, 4, 4, 1])

if __name__ == "__main__":
    unittest.main(verbosity=2)
