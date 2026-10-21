#!/usr/bin/env python3
"""Installer helper: check a downloaded source tarball against its pinned sha256, then unpack it safely.

  python3 lib/verify_unpack.py <tarball> <sha256> <dest-dir> <module>

Nothing is unpacked unless the sha256 matches. The top folder (<name>-<commit>/) is stripped; absolute
paths, "..", links, and devices are skipped. Fails if <module>.py is not in the result. Standard library only.
"""
import hashlib, os, sys, tarfile

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()

def main(src, want, dest, module):
    got = sha256(src)
    if got != want.lower():
        sys.exit(f"sha256 mismatch: got {got}, pinned {want}")
    with tarfile.open(src, "r:gz") as t:
        for m in t.getmembers():
            parts = m.name.split("/", 1)
            if len(parts) < 2 or not parts[1]:
                continue
            rel = os.path.normpath(parts[1])
            if os.path.isabs(rel) or rel == ".." or rel.startswith(".." + os.sep) or not (m.isfile() or m.isdir()):
                continue
            out = os.path.join(dest, rel)
            if m.isdir():
                os.makedirs(out, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with t.extractfile(m) as r, open(out, "wb") as w:
                w.write(r.read())
    if not os.path.isfile(os.path.join(dest, module + ".py")):
        sys.exit("library module missing from the download")

if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
