#!/usr/bin/env python3
"""Fail closed when trusted provider source licensing changes."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


EXPECTED_LICENSES = {"aosp": "Apache-2.0", "mbpi": "CC-PDDC"}
AOSP_MARKERS = (
    "Copyright 2006, The Android Open Source Project",
    'Licensed under the Apache License, Version 2.0 (the "License")',
    "http://www.apache.org/licenses/LICENSE-2.0",
)
MBPI_MARKERS = (
    "THIS WORK IS IN PUBLIC DOMAIN:",
    "dedicates whatever copyright the dedicators holds",
    "freely reproduced, distributed, transmitted, used, modified, built upon",
)


def require_markers(path: Path, source_name: str, markers: tuple[str, ...]) -> None:
    text = " ".join(path.read_text(encoding="utf-8").split())
    missing = [marker for marker in markers if " ".join(marker.split()) not in text]
    if missing:
        raise SystemExit(
            f"{source_name} licensing changed or is incomplete in {path}: "
            + ", ".join(repr(marker) for marker in missing)
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--mbpi", required=True, type=Path)
    parser.add_argument("--aosp", required=True, type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if manifest.get("format") != 1:
        raise SystemExit("unsupported provider source manifest")
    for name, expected in EXPECTED_LICENSES.items():
        actual = manifest.get("sources", {}).get(name, {}).get("license")
        if actual != expected:
            raise SystemExit(
                f"unexpected {name} license identifier: {actual!r}; expected {expected!r}"
            )

    require_markers(args.aosp, "AOSP", AOSP_MARKERS)
    require_markers(args.mbpi, "GNOME MBPI", MBPI_MARKERS)
    print("Provider source licenses verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
