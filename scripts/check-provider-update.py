#!/usr/bin/env python3
"""Reject anomalous generated provider database updates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as source:
        return json.load(source)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--old-report", required=True, type=Path)
    parser.add_argument("--new-report", required=True, type=Path)
    parser.add_argument("--old-database", required=True, type=Path)
    parser.add_argument("--new-database", required=True, type=Path)
    args = parser.parse_args()

    old = load(args.old_report)
    new = load(args.new_report)
    errors: list[str] = []

    for metric in ("profiles", "mccmnc", "unique_apns"):
        if new[metric] < old[metric]:
            errors.append(f"{metric} decreased: {old[metric]} -> {new[metric]}")
    if new["profiles"] > max(old["profiles"] + 500, int(old["profiles"] * 1.25)):
        errors.append(f"profile count grew anomalously: {old['profiles']} -> {new['profiles']}")

    old_size = args.old_database.stat().st_size
    new_size = args.new_database.stat().st_size
    if new_size > max(old_size + 50000, int(old_size * 1.30)):
        errors.append(f"database size grew anomalously: {old_size} -> {new_size}")

    for name in ("mbpi", "aosp"):
        revision = new.get("sources", {}).get(name, {}).get("revision", "")
        if len(revision) != 40 or any(char not in "0123456789abcdef" for char in revision):
            errors.append(f"invalid {name} revision in generated report")

    if errors:
        raise SystemExit("unsafe provider update:\n  " + "\n  ".join(errors))
    print(
        f"provider update accepted: profiles {old['profiles']} -> {new['profiles']}, "
        f"MCC/MNC {old['mccmnc']} -> {new['mccmnc']}, bytes {old_size} -> {new_size}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
