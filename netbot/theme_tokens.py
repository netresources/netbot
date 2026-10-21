"""Colors and type for the dashboard, read at build time from the shipped theme files in netbot/theme/.

netbot/theme/ holds verbatim copies of the design files (tokens.css, netbot-theme.css, netbot-dark.mplstyle).
They are the only place a color value is written. Everything else (HTML, SVG, PNG) uses the token names:
CSS through var(--nb-*) and the nb-* classes, matplotlib through the dicts below, which are parsed from
tokens.css. To change a color, replace the theme files; no code changes.
"""
import re
from pathlib import Path

THEME_DIR = Path(__file__).resolve().parent / "theme"
TOKENS_CSS = THEME_DIR / "tokens.css"
THEME_CSS = THEME_DIR / "netbot-theme.css"
MPLSTYLE = THEME_DIR / "netbot-dark.mplstyle"

# Metric names, in token order (--metric-<name>); same order as the chart color cycle.
METRIC_NAMES = ("latency", "ping-drop", "throughput", "obstruction", "gateway-ping",
                "internet-latency", "packet-loss", "speed-test", "router-devices")
# tiles() level -> (token, CSS class suffix, word, PNG mark). OK is always a filled dot plus the word OK.
LEVELS = {"green": ("--nb-ok", "ok", "OK", "\u25CF"), "yellow": ("--nb-warn", "warn", "WARN", "\u25B2"),
          "red": ("--nb-alert", "alert", "ALERT", "\u25C6"), "gray": ("--nb-nodata", "nodata", "NO DATA", "\u25CB")}

_DECL = re.compile(r"(--[\w-]+)\s*:\s*([^;]+);")
_VAR = re.compile(r"var\((--[\w-]+)\)")

def css_vars(path=TOKENS_CSS):
    """{--name: value} from the :root block of tokens.css, comments stripped, var() references resolved."""
    text = re.sub(r"/\*.*?\*/", "", Path(path).read_text(encoding="utf-8"), flags=re.S)
    root = text[text.index(":root"):]
    root = root[:root.index("}")]
    v = {k: val.strip() for k, val in _DECL.findall(root)}
    for _ in range(5):
        v = {k: _VAR.sub(lambda m: v.get(m.group(1), m.group(0)), val) for k, val in v.items()}
    return v

def mpl_colors(path=TOKENS_CSS):
    """Plain dicts for matplotlib, all from tokens.css."""
    v = css_vars(path)
    return {
        "bg": v["--nb-bg"], "panel": v["--nb-panel"], "raised": v["--nb-raised"], "grid": v["--nb-grid"],
        "hair": v["--nb-hairline"], "line": v["--nb-line"], "text": v["--nb-text"], "text2": v["--nb-text-2"],
        "text3": v["--nb-text-3"], "accent": v["--nb-accent"],
        "metric": {n: v["--metric-" + n] for n in METRIC_NAMES},
        "fill_alpha": float(v["--nb-metric-fill-opacity"]),
        "status": {lvl: v[tok] for lvl, (tok, _, _, _) in LEVELS.items()},
    }

def inline_css():
    """tokens.css and netbot-theme.css, for the self-contained snapshot. netbot-live.css is not included."""
    return TOKENS_CSS.read_text(encoding="utf-8") + "\n" + THEME_CSS.read_text(encoding="utf-8")
