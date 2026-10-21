#!/usr/bin/env python3
"""One-time migration of NetBot 0.1-0.4 key names to the current ones (stdlib only).

Older versions used a different name for the config section, the dish-library path key, and the per-sample
data key. This reads that old name once and rewrites, in place:
  - <home>/config.toml          [old] section -> [dish], old path key -> the current one
  - <data_dir>/*.jsonl          the old data key in every sample -> the current data key
  - <sync_dir>/latest.json      the same, in the synced copy
Then it writes <home>/.netbot-state/migrated-keys so it never runs again. Nothing is deleted; each file is
rewritten through a temporary file and an atomic rename. Run by install.sh before it writes the new config.
Usage: migrate_legacy.py <NetBot home>     Prints one line per rewritten file.
"""
import json, os, re, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dish_constants import DISH_CFG_SECTION, DISH_PATHS_KEY, DISH_DATA_KEY  # noqa: E402

LEGACY_KEY = "starlink"
LEGACY_SECTION, LEGACY_PATHS_KEY, LEGACY_DATA_KEY = LEGACY_KEY, LEGACY_KEY + "_tools", LEGACY_KEY
MARKER = "migrated-keys"

def _write(path, text):
    tmp = path.with_name(path.name + ".migrate")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)

def migrate_config(path):
    if not path.is_file():
        return False
    old = path.read_text(encoding="utf-8")
    new = re.sub(rf"^\[{re.escape(LEGACY_SECTION)}\]\s*$", f"[{DISH_CFG_SECTION}]", old, flags=re.M)
    new = re.sub(rf"^{re.escape(LEGACY_PATHS_KEY)}(\s*=)", rf"{DISH_PATHS_KEY}\1", new, flags=re.M)
    if new != old:
        _write(path, new)
    return new != old

def _rename_key(obj):
    if isinstance(obj, dict) and LEGACY_DATA_KEY in obj and DISH_DATA_KEY not in obj:
        return {(DISH_DATA_KEY if k == LEGACY_DATA_KEY else k): v for k, v in obj.items()}, True
    return obj, False

def migrate_jsonl(path):
    out, changed = [], False
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            obj, c = _rename_key(json.loads(line))
        except ValueError:
            out.append(line)          # keep unreadable lines exactly as they were
            continue
        out.append(json.dumps(obj) if c else line)
        changed |= c
    if changed:
        _write(path, "\n".join(out) + "\n")
    return changed

def migrate_json(path):
    if not path.is_file():
        return False
    try:
        obj, c = _rename_key(json.loads(path.read_text(encoding="utf-8")))
    except ValueError:
        return False
    if c:
        _write(path, json.dumps(obj, indent=1))
    return c

def _config_paths(cfg_text, home):
    get = lambda k: (re.search(rf'^{k}\s*=\s*"([^"]*)"', cfg_text, re.M) or [None, ""])[1]
    data = Path(os.path.expanduser(get("data_dir") or str(home / "data")))
    sync = get("sync_dir")
    return data, (Path(os.path.expanduser(sync)) if sync else None)

def run(home):
    home = Path(home)
    state = home / ".netbot-state"
    if (state / MARKER).exists():
        return []
    cfg = home / "config.toml"
    data_dir, sync_dir = _config_paths(cfg.read_text(encoding="utf-8") if cfg.is_file() else "", home)
    done = []
    if migrate_config(cfg):
        done.append(cfg)
    for f in sorted(data_dir.glob("*.jsonl")) if data_dir.is_dir() else []:
        if migrate_jsonl(f):
            done.append(f)
    if sync_dir and migrate_json(sync_dir / "latest.json"):
        done.append(sync_dir / "latest.json")
    state.mkdir(parents=True, exist_ok=True)
    (state / MARKER).write_text("1\n", encoding="utf-8")
    return done

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: migrate_legacy.py <NetBot home>")
    for f in run(sys.argv[1]):
        print(f"migrated {f}")
