#!/usr/bin/env python3
"""Resolve trusted provider repositories and write an updated manifest."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


SHA_RE = re.compile(r"[0-9a-f]{40}")


def resolve_head(repository: str) -> str:
    result = subprocess.run(
        ["git", "ls-remote", repository, "HEAD"],
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    )
    fields = result.stdout.split()
    if len(fields) < 2 or fields[1] != "HEAD" or not SHA_RE.fullmatch(fields[0]):
        raise RuntimeError(f"unexpected ls-remote response for {repository!r}")
    return fields[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    with args.manifest.open(encoding="utf-8") as source:
        manifest = json.load(source)
    if manifest.get("format") != 1:
        raise ValueError("unsupported provider source manifest")

    for name in ("mbpi", "aosp"):
        source = manifest["sources"][name]
        source["revision"] = resolve_head(source["repository"])

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
        output.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
