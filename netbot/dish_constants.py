#!/usr/bin/env python3
"""Dish constants. This is the only NetBot file that names the dish's maker or the third-party dish
library; everywhere else, code and wording say "dish". Standard library only.

  python3 dish_constants.py --shell   prints these values as shell variables for install.sh
"""
import shlex, sys

# gRPC service the dish answers on (fixed by the dish firmware; read-only use).
DISH_GRPC_SERVICE = "SpaceX.API.Device.Device"
# Third-party dish library: downloaded during setup, never bundled. Pinned to one reviewed commit and
# checked against the sha256 of that commit's source tarball (verified 2026-10-19: two downloads,
# identical bytes, contents identical to a git checkout of the commit). (name, module, owner, commit, sha256)
DISH_LIB_PIN = ("starlink-grpc-tools", "starlink_grpc", "sparky8512", "0d9809e8d890ce8f254ea2cabc04d5161050962a", "a77933e20ce6f9a02bbcdedf3a91ff02055f63e72e7d7a9e5383be0b28c2edc0")
DISH_LIB_NAME, DISH_LIB_MODULE, DISH_LIB_OWNER, DISH_LIB_COMMIT, DISH_LIB_SHA256 = DISH_LIB_PIN
DISH_LIB_URL = f"https://codeload.github.com/{DISH_LIB_OWNER}/{DISH_LIB_NAME}/tar.gz/{DISH_LIB_COMMIT}"
DISH_LIB_DIR = "dish-lib"                 # folder under ~/NetBot where setup unpacks it
DISH_LIB_LEGACY_DIR = DISH_LIB_NAME       # folder name used by NetBot 0.1-0.3 (removed on upgrade)

# The dish's fixed local address and port (the same for every dish).
DISH_HOST = "192.168.100.1"
DISH_PORT = 9200

# Config section, config path key, and sample/data key. Files written by older versions are rewritten
# once by migrate_legacy.py (run by install.sh).
DISH_CFG_SECTION = "dish"
DISH_PATHS_KEY = "dish_lib"
DISH_DATA_KEY = "dish"

def values():
    return {"DISH_LIB_URL": DISH_LIB_URL, "DISH_LIB_COMMIT": DISH_LIB_COMMIT, "DISH_LIB_SHA256": DISH_LIB_SHA256,
            "DISH_LIB_MODULE": DISH_LIB_MODULE, "DISH_LIB_DIR": DISH_LIB_DIR, "DISH_LIB_LEGACY_DIR": DISH_LIB_LEGACY_DIR,
            "DISH_DEFAULT_HOST": DISH_HOST, "DISH_PORT": str(DISH_PORT), "DISH_CFG_SECTION": DISH_CFG_SECTION,
            "DISH_PATHS_KEY": DISH_PATHS_KEY, "DISH_DATA_KEY": DISH_DATA_KEY}

def shell():
    """For install.sh: eval "$(python3 dish_constants.py --shell)"."""
    return "\n".join(f"{k}={shlex.quote(v)}" for k, v in values().items())

def as_json():
    """The same values as JSON, for install.ps1 on Windows."""
    import json
    return json.dumps(values())

if __name__ == "__main__":
    if sys.argv[1:] == ["--shell"]:
        print(shell())
    elif sys.argv[1:] == ["--json"]:
        print(as_json())
    else:
        sys.exit("usage: dish_constants.py --shell | --json")
