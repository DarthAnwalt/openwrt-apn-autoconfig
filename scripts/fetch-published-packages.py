#!/usr/bin/env python3
"""Fetch released APKs from the public feed and verify their indexed hashes."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


DEFAULT_BASE = "https://darthanwalt.github.io/openwrt-apn-autoconfig/25.12/noarch"
DEFAULT_CHECKSUMS = "https://darthanwalt.github.io/openwrt-apn-autoconfig/SHA256SUMS"
SAFE_FIELD = re.compile(r"[A-Za-z0-9._+~-]+")
SHA256 = re.compile(r"[0-9a-f]{64}")
MAX_APK_BYTES = 100 * 1024 * 1024


def fail(message: str) -> None:
    raise SystemExit(f"published-feed fetch failed: {message}")


def fetch(url: str, limit: int) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "apn-autoconfig-release"})
    with urllib.request.urlopen(request, timeout=60) as response:
        length = response.headers.get("Content-Length")
        if length and int(length) > limit:
            fail(f"{url} exceeds the size limit")
        data = response.read(limit + 1)
    if len(data) > limit:
        fail(f"{url} exceeds the size limit")
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=DEFAULT_BASE)
    parser.add_argument("--checksums-url", default=DEFAULT_CHECKSUMS)
    parser.add_argument("--output", required=True, type=Path)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--exclude", action="append", default=[])
    selection.add_argument("--only", action="append", default=[])
    args = parser.parse_args()

    base = args.base_url.rstrip("/")
    try:
        index = json.loads(fetch(f"{base}/packages.json", 5 * 1024 * 1024))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        fail(f"could not read packages.json: {error}")
    packages = index.get("packages")
    if not isinstance(packages, list):
        fail("packages.json has no package list")

    checksum_entries: dict[str, str] = {}
    try:
        checksum_text = fetch(args.checksums_url, 5 * 1024 * 1024).decode("ascii")
    except (OSError, UnicodeDecodeError) as error:
        fail(f"could not read SHA256SUMS: {error}")
    for line in checksum_text.splitlines():
        parts = line.split("  ", 1)
        if len(parts) != 2 or not SHA256.fullmatch(parts[0]):
            fail("SHA256SUMS contains an invalid entry")
        digest, path = parts
        if path in checksum_entries:
            fail(f"SHA256SUMS contains {path} more than once")
        checksum_entries[path] = digest

    wanted: list[tuple[str, str]] = []
    seen: set[str] = set()
    selected_names: set[str] = set()
    for package in packages:
        if not isinstance(package, dict):
            fail("packages.json contains a non-object package entry")
        name = package.get("name")
        version = package.get("version")
        package_hash = package.get("hashes")
        if not all(isinstance(value, str) and SAFE_FIELD.fullmatch(value) for value in (name, version)):
            fail("packages.json contains an unsafe package name or version")
        if not isinstance(package_hash, str) or not SHA256.fullmatch(package_hash):
            fail(f"{name} has no valid package-content hash")
        if name in seen:
            fail(f"packages.json contains {name} more than once")
        seen.add(name)
        if args.only and name not in args.only:
            continue
        if name in args.exclude:
            continue
        filename = f"{name}-{version}.apk"
        checksum_path = f"25.12/noarch/{filename}"
        digest = checksum_entries.get(checksum_path)
        if digest is None:
            fail(f"SHA256SUMS has no entry for {filename}")
        wanted.append((filename, digest))
        selected_names.add(name)

    if not wanted:
        fail("the selection contains no packages")
    if args.only and selected_names != set(args.only):
        fail("one or more requested packages are absent from the feed")

    args.output.mkdir(parents=True, exist_ok=True)
    for filename, expected in wanted:
        url = f"{base}/{urllib.parse.quote(filename)}"
        payload = fetch(url, MAX_APK_BYTES)
        actual = hashlib.sha256(payload).hexdigest()
        if actual != expected:
            fail(f"the published hash does not match {filename}")
        temporary = args.output / f".{filename}.tmp"
        temporary.write_bytes(payload)
        temporary.replace(args.output / filename)
        print(f"Fetched and verified {filename}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.URLError as error:
        fail(f"network request failed: {error.reason}")
