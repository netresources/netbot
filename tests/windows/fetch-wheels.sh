#!/usr/bin/env bash
# Fills the local wheel cache the Windows installer tests install from (pip --no-index --find-links),
# so the tests need no PyPI access inside the sandbox. Run this once, with network, before the tests.
#   NETBOT_WHEEL_DIR  where the wheels go (default: tests/windows/wheels, gitignored)
#   PYTHON            the python whose pip downloads them (default: python3)
# Extra arguments go to `pip download` (e.g. --platform/--python-version for another target).
# Only downloads into the wheel folder; it never deletes anything.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="${NETBOT_WHEEL_DIR:-$here/wheels}"
mkdir -p "$dir"
"${PYTHON:-python3}" -m pip download --disable-pip-version-check --only-binary=:all: \
  -r "$here/wheel-requirements.txt" -d "$dir" "$@"
echo "wheels in $dir"
