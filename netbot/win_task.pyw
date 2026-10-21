"""Windows Task Scheduler entry point for the NetBot collector (run with pythonw.exe, so no console window opens).
Sends the collector's output to <NetBot>/logs/collect.log, as the launchd job does on a Mac."""
import os, sys, traceback
from pathlib import Path

here = Path(__file__).resolve().parent
logs = here.parent / "logs"
logs.mkdir(parents=True, exist_ok=True)
log = open(logs / "collect.log", "a", encoding="utf-8")
sys.stdout = sys.stderr = log
os.chdir(here)
sys.path.insert(0, str(here))
try:
    import collect
    collect.main()
except Exception:
    traceback.print_exc()
    sys.exit(1)
finally:
    log.flush()
