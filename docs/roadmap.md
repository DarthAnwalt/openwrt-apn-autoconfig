# Architecture roadmap

This roadmap records the current direction rather than a promise that every
minor release will contain exactly the listed work. Hardware findings and
adapter constraints may change the sequence. The safety invariants remain
binding: never mutate an ambiguous target, never claim a capability that is
not implemented, verify connectivity before keeping a profile, and restore the
previous profile after failure.

## 0.9.0 — adapter foundation

0.9.0 separates the APN selection engine from modem discovery, SIM identity
collection and netifd profile application. It must preserve the complete
working ModemManager behavior of 0.8.x while publishing a versioned,
target-aware API that other applications can consume without the LuCI package.

Scope:

- discover configured cellular network sections and expose each as a stable
  target with its netifd protocol and declared capabilities;
- recognize `modemmanager`, `qmi`, `mbim`, `fibocom`, `atc`, `xmm`, `ncm`,
  `wwan` and `3g` targets, without treating recognition as write support;
- provide a complete ModemManager identity and profile adapter;
- report non-ModemManager targets as read-only inventory entries with
  `identity=false` and `profile_apply=false` until their adapters exist;
- reject unsupported and ambiguous mutating operations before changing UCI,
  restarting an interface or touching persistent state;
- resolve the effective layer-3 device from netifd/ubus instead of requiring a
  fixed `wwan0` name for connectivity tests;
- version the JSON target and operation contracts and retain the existing
  narrow read-only and mutating rpcd entry points;
- namespace persistent active/baseline state by target while retaining the
  ICCID profile cache as SIM-owned state;
- migrate the 0.8.x single-target state without losing the exact rollback
  baseline;
- keep the LuCI package optional and make it a consumer of the same public core
  API available to external applications;
- cover discovery, capabilities, ambiguity, migration, rollback, input
  validation and adapter isolation with synthetic and security tests;
- validate installation, reconciliation, connectivity verification, rollback,
  reboot behavior and removal recovery on the reference router before release.

Out of scope:

- QMI, MBIM, AT, Fibocom or other non-ModemManager profile mutation;
- eSIM profile management, `lpac`, SMS, USSD, band control or modem UI work;
- a dependency on `luci-app-5gmodem` or any other external modem UI;
- automatic selection between multiple equally eligible cellular targets.

The distinction between recognition and support is part of the public API. A
recognized target must declare its capabilities explicitly. An unsupported
backend is a normal inventory result, not a partially functional fallback.

## 0.9.1 — native QMI adapter

Development started as 0.9.1-alpha. The hardware-independent phase adds a
bounded read-only `uqmi` identity adapter, a backend contract, runtime/evidence
states and synthetic home, roaming, malformed-output and injection coverage.
It also removes the core package's hard dependency on a particular modem
manager. QMI profile write/apply remains false until netifd option mapping,
rollback and live hardware validation pass on the isolated test router.

## 0.9.2 — native MBIM adapter

Planned for a separate task. Add MBIM SIM identity collection, profile mapping
and correct handling of dynamically created IPv4/IPv6 child interfaces.

## 0.9.3 — generic AT identity

Planned for a separate task. Add a bounded AT transport and normalized SIM and
registration identity without coupling the APN matcher to vendor commands.

## 1.0 — stable multi-backend engine

The 1.0 objective is a hardware-independent APN engine usable with configured
ModemManager, QMI, MBIM and selected AT-managed usbnet modems. Fibocom FM350-GL
support is a target for this milestone, either through a separately installed
compatible netifd handler or an optional independently implemented handler.
RNDIS/ECM alone is not an APN control protocol, so support is defined by the
control adapter used with the usbnet data device rather than by the network
driver name.

The core remains independent of every GUI. `luci-app-apn-autoconfig` is the
project's optional frontend; applications such as `luci-app-5gmodem` may use
the versioned query/control API without either project owning the other's
modem-management responsibilities.
