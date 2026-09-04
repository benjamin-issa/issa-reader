#!/usr/bin/env python3
"""Renames a sweep's exported xcresult attachments into a per-device folder.

`xcresulttool export attachments` writes opaque filenames plus a manifest that
carries the name the test asked for. The test names each shot
`<device>__<screen>.png`, which is what this reads back.
"""
import json
import re
import shutil
import sys
from pathlib import Path

def main(source: Path, destination: Path) -> int:
    manifest = source / "manifest.json"
    if not manifest.exists():
        print(f"no manifest in {source}", file=sys.stderr)
        return 0

    destination.mkdir(parents=True, exist_ok=True)
    kept = 0
    for entry in json.loads(manifest.read_text()):
        for attachment in entry.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName") or ""
            exported = attachment.get("exportedFileName")
            if not exported or "__" not in name or not name.endswith(".png"):
                continue
            # XCTest appends `_<index>_<UUID>` to the name the test asked for,
            # so "iphone-17-pro__library.png" comes back as
            # "iphone-17-pro__library_0_A1084AA1-….png". Strip it, or every run
            # writes a new file and the contact sheet grows one column per run.
            screen = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", ".png", name.split("__", 1)[1])
            source_file = source / exported
            if not source_file.exists():
                continue
            shutil.copyfile(source_file, destination / screen)
            kept += 1
    print(f"  {kept} screenshots -> {destination}")
    return 0

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: collect-sweep-shots.py <attachments-dir> <out-dir>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(Path(sys.argv[1]), Path(sys.argv[2])))
