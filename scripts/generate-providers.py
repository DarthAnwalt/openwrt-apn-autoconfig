#!/usr/bin/env python3
"""Generate the compact runtime APN database from upstream XML sources."""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, fields, replace
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "data/provider-sources.json"
DEFAULT_OVERRIDES = ROOT / "data/providers-overrides.tsv"
DEFAULT_VERSION_FILE = ROOT / "apn-autoconfig-providers/VERSION"
DEFAULT_OUTPUT = ROOT / "apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"
APN_RE = re.compile(r"[A-Za-z0-9._-]+")
DIGIT_PATTERN_RE = re.compile(r"[0-9xX]+")
DATABASE_VERSION_RE = re.compile(r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}")
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"
SERVICE_ONLY_APNS = {"ims", "vzwims"}


@dataclass(frozen=True)
class Row:
    mccmnc: str
    imsi_pattern: str
    iccid_pattern: str
    gid1: str
    spn: str
    provider: str
    apn: str
    priority: int
    username: str = "-"
    password: str = "-"
    auth: str = "-"
    ip_type: str = "-"

    def profile_key(self) -> tuple[str, ...]:
        return (
            self.mccmnc,
            self.imsi_pattern,
            self.iccid_pattern,
            self.gid1.lower(),
            self.spn.lower(),
            self.apn.lower(),
            self.username,
            self.password,
            self.auth,
            self.ip_type,
        )

    def as_tsv(self) -> str:
        values = [getattr(self, field.name) for field in fields(self)]
        return "\t".join(str(value) for value in values)


class Generator:
    def __init__(self) -> None:
        self.rows: dict[tuple[str, ...], Row] = {}
        self.stats: dict[str, int] = {}
        self.warnings: list[str] = []

    def count(self, key: str, amount: int = 1) -> None:
        self.stats[key] = self.stats.get(key, 0) + amount

    def add(self, row: Row, source: str) -> None:
        validate_row(row)
        key = row.profile_key()
        current = self.rows.get(key)
        if current is None or row.priority < current.priority:
            self.rows[key] = row
            self.count(f"{source}_accepted")
        else:
            self.count(f"{source}_duplicates")

    def warn(self, source: str, message: str) -> None:
        self.count(f"{source}_skipped")
        self.warnings.append(f"{source}: {message}")


def clean_text(value: str | None, default: str = "-") -> str:
    value = (value or "").strip()
    if not value:
        return default
    if any(char in value for char in "\t\r\n"):
        raise ValueError("tabs and newlines are not allowed")
    return value


def clean_apn(value: str | None) -> str:
    value = (value or "").strip()
    if not APN_RE.fullmatch(value):
        raise ValueError(f"invalid APN {value!r}")
    return value.lower()


def clean_mccmnc(mcc: str | None, mnc: str | None) -> str:
    mcc = (mcc or "").strip()
    mnc = (mnc or "").strip()
    if not re.fullmatch(r"[0-9]{3}", mcc) or not re.fullmatch(r"[0-9]{2,3}", mnc):
        raise ValueError(f"invalid MCC/MNC {mcc!r}/{mnc!r}")
    return mcc + mnc


def validate_row(row: Row) -> None:
    if not re.fullmatch(r"[0-9]{5,6}", row.mccmnc):
        raise ValueError(f"invalid mccmnc {row.mccmnc!r}")
    for name in ("imsi_pattern", "iccid_pattern"):
        value = getattr(row, name)
        if value != "-" and not DIGIT_PATTERN_RE.fullmatch(value):
            raise ValueError(f"invalid {name} {value!r}")
    if not APN_RE.fullmatch(row.apn):
        raise ValueError(f"invalid APN {row.apn!r}")
    if row.priority < 0 or row.priority > 999999:
        raise ValueError(f"invalid priority {row.priority}")
    if row.auth not in ("-", "none", "pap", "chap", "pap-or-chap"):
        raise ValueError(f"invalid auth {row.auth!r}")
    if row.ip_type not in ("-", "ipv4", "ipv6", "ipv4v6"):
        raise ValueError(f"invalid ip_type {row.ip_type!r}")
    for field in fields(row):
        value = str(getattr(row, field.name))
        if any(char in value for char in "\t\r\n"):
            raise ValueError(f"invalid whitespace in {field.name}")


def first_name(element: ET.Element) -> str:
    names = element.findall("name")
    preferred = next((item.text for item in names if item.get(XML_LANG) is None), None)
    return clean_text(preferred or (names[0].text if names else None), "Unknown provider")


def import_mbpi(path: Path, generator: Generator) -> None:
    root = ET.parse(path).getroot()
    for provider in root.findall("./country/provider"):
        gsm = provider.find("gsm")
        if gsm is None:
            continue
        provider_name = first_name(provider)
        network_ids = gsm.findall("network-id")
        if not network_ids:
            generator.warn("mbpi", f"{provider_name}: no network-id")
            continue
        gid_values = [clean_text(item.text).upper() for item in gsm.findall("gid1")] or ["-"]
        primary_offset = 0 if provider.get("primary") == "true" else 100

        for apn_index, apn_node in enumerate(gsm.findall("apn")):
            usages = {item.get("type") for item in apn_node.findall("usage")}
            if usages and not usages.intersection(
                {"internet", "ia", "mms-internet-hipri", "mms-internet-hipri-fota"}
            ):
                generator.count("mbpi_non_internet")
                continue
            try:
                apn = clean_apn(apn_node.get("value"))
            except ValueError as error:
                generator.warn("mbpi", f"{provider_name}: {error}")
                continue
            if apn in SERVICE_ONLY_APNS:
                generator.count("mbpi_non_internet")
                continue

            plans = [item.get("type") for item in apn_node.findall("plan") if item.get("type")]
            label = provider_name
            if plans:
                label += " (" + "/".join(plans) + ")"
            usage_offset = 0 if "internet" in usages else 20 if not usages else 40
            auth_node = apn_node.find("authentication")
            auth = auth_node.get("method") if auth_node is not None else "-"
            username = clean_text(apn_node.findtext("username"))
            password = clean_text(apn_node.findtext("password"))
            priority = 100 + primary_offset + usage_offset + min(apn_index, 99)

            for network_id in network_ids:
                try:
                    mccmnc = clean_mccmnc(network_id.get("mcc"), network_id.get("mnc"))
                except ValueError as error:
                    generator.warn("mbpi", f"{provider_name}: {error}")
                    continue
                for gid1 in gid_values:
                    generator.add(
                        Row(
                            mccmnc=mccmnc,
                            imsi_pattern="-",
                            iccid_pattern="-",
                            gid1=gid1,
                            spn="-",
                            provider=clean_text(label),
                            apn=apn,
                            priority=priority,
                            username=username,
                            password=password,
                            auth=auth,
                            ip_type="-",
                        ),
                        "mbpi",
                    )


def android_auth(value: str | None) -> str:
    return {None: "-", "": "-", "-1": "-", "0": "none", "1": "pap", "2": "chap", "3": "pap-or-chap"}.get(
        value, "-"
    )


def android_ip_type(value: str | None) -> str:
    return {"IP": "ipv4", "IPV6": "ipv6", "IPV4V6": "ipv4v6"}.get((value or "").upper(), "-")


def import_aosp(path: Path, generator: Generator) -> None:
    root = ET.parse(path).getroot()
    for index, node in enumerate(root.findall("apn")):
        if node.get("carrier_enabled", "true").lower() == "false":
            generator.count("aosp_disabled")
            continue
        types = {item for item in (node.get("type") or "").split(",") if item}
        if types and not types.intersection({"default", "ia"}):
            generator.count("aosp_non_internet")
            continue
        if node.get("mcc") == "001":
            generator.count("aosp_test_network")
            continue
        provider = clean_text(node.get("carrier"), "Unknown provider")
        try:
            mccmnc = clean_mccmnc(node.get("mcc"), node.get("mnc"))
            apn = clean_apn(node.get("apn"))
        except ValueError as error:
            generator.warn("aosp", f"{provider}: {error}")
            continue
        if apn in SERVICE_ONLY_APNS:
            generator.count("aosp_non_internet")
            continue

        imsi_pattern = iccid_pattern = gid1 = spn = "-"
        mvno_type = node.get("mvno_type")
        match_data = clean_text(node.get("mvno_match_data"))
        if mvno_type:
            if match_data == "-":
                generator.warn("aosp", f"{provider}: {mvno_type} without match data")
                continue
            if mvno_type == "imsi":
                imsi_pattern = match_data.lower()
            elif mvno_type == "iccid":
                iccid_pattern = match_data.lower()
            elif mvno_type == "gid":
                gid1 = match_data.upper()
            elif mvno_type == "spn":
                spn = match_data
            else:
                generator.warn("aosp", f"{provider}: unknown MVNO type {mvno_type!r}")
                continue

        role_offset = 0 if "default" in types else 20
        generator.add(
            Row(
                mccmnc=mccmnc,
                imsi_pattern=imsi_pattern,
                iccid_pattern=iccid_pattern,
                gid1=gid1,
                spn=spn,
                provider=provider,
                apn=apn,
                priority=500 + role_offset + min(index, 9999),
                username=clean_text(node.get("user")),
                password=clean_text(node.get("password")),
                auth=android_auth(node.get("authtype")),
                ip_type=android_ip_type(node.get("protocol")),
            ),
            "aosp",
        )


def import_overrides(path: Path, generator: Generator) -> None:
    with path.open(encoding="utf-8") as source:
        for line_number, raw_line in enumerate(source, 1):
            line = raw_line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            values = line.split("\t")
            if len(values) != 12:
                raise ValueError(f"{path}:{line_number}: expected 12 fields, got {len(values)}")
            values[7] = int(values[7])
            generator.add(Row(*values), "overrides")


def import_previous(path: Path, generator: Generator) -> None:
    with path.open(encoding="utf-8") as source:
        for line_number, raw_line in enumerate(source, 1):
            line = raw_line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            values = line.split("\t")
            if len(values) != 12:
                raise ValueError(f"{path}:{line_number}: expected 12 fields, got {len(values)}")
            values[7] = int(values[7])
            old_row = Row(*values)
            if old_row.profile_key() in generator.rows:
                continue
            demoted = replace(old_row, priority=min(900000, old_row.priority + 50000))
            validate_row(demoted)
            generator.rows[demoted.profile_key()] = demoted
            generator.count("previous_retained")


def load_manifest(path: Path) -> dict:
    with path.open(encoding="utf-8") as source:
        manifest = json.load(source)
    if manifest.get("format") != 1:
        raise ValueError("unsupported provider source manifest")
    return manifest


def write_database(
    path: Path,
    generator: Generator,
    manifest: dict,
    database_version: str,
    include_aosp: bool,
    include_previous: bool,
) -> None:
    source_names = ["mbpi"] + (["aosp"] if include_aosp else [])
    if include_previous:
        source_names.append("retained previous fallbacks")
    source_names.append("local overrides")
    source_revisions = [
        f"mbpi@{manifest['sources']['mbpi']['revision']}",
    ]
    if include_aosp:
        source_revisions.append(f"aosp@{manifest['sources']['aosp']['revision']}")
    rows = sorted(
        generator.rows.values(),
        key=lambda row: (
            row.mccmnc,
            row.priority,
            row.provider.casefold(),
            row.apn,
            row.imsi_pattern,
            row.iccid_pattern,
            row.gid1,
            row.spn.casefold(),
        ),
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as output:
        output.write("# apn-autoconfig generated provider database v2\n")
        output.write(f"# database-version: {database_version}\n")
        output.write("# database-format: 2\n")
        output.write(f"# sources: {', '.join(source_names)}\n")
        output.write(f"# revisions: {', '.join(source_revisions)}\n")
        output.write("# TAB-separated columns:\n")
        output.write(
            "# mccmnc  imsi_pattern  iccid_pattern  gid1  spn  provider  apn  priority  username  password  auth  ip_type\n"
        )
        output.write("# '-' means unspecified; x in IMSI/ICCID patterns matches one decimal digit.\n")
        for row in rows:
            output.write(row.as_tsv() + "\n")


def write_report(
    path: Path, generator: Generator, manifest: dict, database_version: str, include_aosp: bool
) -> None:
    rows = list(generator.rows.values())
    report = {
        "format": 1,
        "database_format": 2,
        "database_version": database_version,
        "sources": {
            key: {
                "revision": manifest["sources"][key]["revision"],
                "license": manifest["sources"][key]["license"],
            }
            for key in (["mbpi", "aosp"] if include_aosp else ["mbpi"])
        },
        "profiles": len(rows),
        "mccmnc": len({row.mccmnc for row in rows}),
        "unique_apns": len({row.apn for row in rows}),
        "mvno_specific_profiles": sum(
            any(value != "-" for value in (row.imsi_pattern, row.iccid_pattern, row.gid1, row.spn))
            for row in rows
        ),
        "credential_profiles": sum(
            any(value != "-" for value in (row.username, row.password, row.auth)) for row in rows
        ),
        "stats": dict(sorted(generator.stats.items())),
        "warnings": generator.warnings,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as output:
        json.dump(report, output, ensure_ascii=False, indent=2, sort_keys=True)
        output.write("\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mbpi", required=True, type=Path, help="path to MBPI serviceproviders.xml")
    parser.add_argument("--aosp", type=Path, help="path to AOSP apns-full-conf.xml")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--overrides", type=Path, default=DEFAULT_OVERRIDES)
    parser.add_argument("--database-version-file", type=Path, default=DEFAULT_VERSION_FILE)
    parser.add_argument("--previous", type=Path, help="previous v2 database whose removed profiles become fallbacks")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", type=Path, help="optional deterministic JSON quality report")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest = load_manifest(args.manifest)
    database_version = args.database_version_file.read_text(encoding="utf-8").strip()
    if not DATABASE_VERSION_RE.fullmatch(database_version):
        raise ValueError(f"invalid database version: {database_version!r}")
    generator = Generator()
    import_mbpi(args.mbpi, generator)
    if args.aosp:
        import_aosp(args.aosp, generator)
    import_overrides(args.overrides, generator)
    if args.previous:
        import_previous(args.previous, generator)
    retained_previous = generator.stats.get("previous_retained", 0) > 0
    write_database(
        args.output,
        generator,
        manifest,
        database_version,
        args.aosp is not None,
        retained_previous,
    )
    if args.report:
        write_report(args.report, generator, manifest, database_version, args.aosp is not None)

    print(f"generated {len(generator.rows)} provider profiles", file=sys.stderr)
    for key in sorted(generator.stats):
        print(f"  {key}: {generator.stats[key]}", file=sys.stderr)
    if generator.warnings:
        print(f"  warnings: {len(generator.warnings)} (first 10 follow)", file=sys.stderr)
        for warning in generator.warnings[:10]:
            print(f"    {warning}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
