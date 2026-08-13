# For Claude / coding assistants

Read [`docs/development-handoff.md`](docs/development-handoff.md) first — it is the
authoritative entry point for any coding assistant working on this repository.
It links to [`docs/backend-contract-v1.md`](docs/backend-contract-v1.md),
[`docs/testing-0.9.2.md`](docs/testing-0.9.2.md) and
[`docs/roadmap.md`](docs/roadmap.md). The README is the user-facing reference;
the changelog records shipped differences rather than future intentions.

If `.local-notes/next-release-architecture.md` exists in the maintainer's
workspace, read it after the public handoff. It contains uncommitted design
discussion and must not be copied into public documentation without an explicit
decision.

## Before proposing any change as done

Runtime, packaging, LuCI, or documentation changes must pass:

```sh
sh scripts/verify.sh
```

A green fixture suite is necessary but not sufficient for a hardware-support
claim — see the latest version-specific testing document for the evidence
ladder (synthetic →
hardware) before marking any backend `stable`/`hardware_validated: true`.

## Non-negotiable safety invariants

See `docs/development-handoff.md` for the full list. In short: resolve one
unambiguous target before any mutation; treat `detect`/`status`/`targets-json`
as strictly read-only; capture and validate the full baseline before the
first write; touch only backend-owned UCI options and only the selected
netifd interface; verify real connectivity before keeping a candidate;
restore the exact prior profile on any failure; never log credentials or
SIM identifiers.

## Commits

This project uses the Developer Certificate of Origin. Sign off every
commit:

```sh
git commit -s
```

## Secrets

Never read, print, copy, or propose changes to `APK_SIGNING_KEY_BASE64` or
any other repository/Actions secret. The private APK signing key must never
enter the source tree, build artifacts, or a commit.

## Hardware access

This repository targets a physical OpenWrt router (Huasifei WH3000 Pro +
Quectel RM520N-GL) on the maintainer's local network. Do not assume that a
session can reach it: verify access before planning a live gate. Hardware
claims require captured router evidence under the current version-specific
test plan and must be recorded before a release is called stable.
