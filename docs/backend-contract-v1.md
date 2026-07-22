# Backend contract v1

This document defines the boundary between the APN decision engine and a modem
backend. The contract is intentionally smaller than a modem-management API.
Backends identify a configured target and map a normalized mobile profile to
that target; candidate ranking, connectivity verification, caching and rollback
belong to the core.

## Capability and evidence are separate

`targets-json` v2 exposes runtime capability independently from implementation
and validation state:

- `capabilities.identity` means the installed backend can currently provide the
  identity required by `detect` and `status`;
- `profile_read`, `profile_write` and `profile_apply` describe separately
  implemented operations and must never be inferred from protocol discovery;
- `implementation_state` is `unimplemented`, `alpha` or `stable`;
- `validation_state` is `none`, `synthetic` or `hardware`;
- `hardware_validated` is false until the backend completes the documented live
  test gate.

An installed parser is not hardware support. A missing runtime command such as
`mmcli`, `uqmi` or the core dependency `sms_tool` makes the corresponding capability false without hiding the
configured cellular target.

## Read-only QMI identity adapter

The 0.9.1 alpha ships `/usr/libexec/apn-autoconfig-qmi`. Its public operations
are deliberately limited to:

```text
apn-autoconfig-qmi capabilities
apn-autoconfig-qmi identity /dev/<safe-qmi-control-device>
```

The adapter accepts only numeric `cdc-wdm` and `wwan…qmi…` control-device names.
The core can obtain that name from an explicit netifd `device` or resolve
exactly one matching control channel below a validated OpenWrt `devpath` in
sysfs. Zero or multiple matches fail closed instead of selecting by enumeration
order.
It first invokes only bounded, read-only `uqmi` operations:

```text
--get-iccid
--get-imsi
--get-serving-system
```

Some QMI modem firmware, including the tested RM520N, reports `Not supported`
for the native ICCID and IMSI operations while serving-system queries work. In
that case the adapter resolves `ttyUSB*`/`ttyACM*` class devices whose canonical
sysfs path belongs to the same physical USB device as the selected QMI control
channel. It probes those ports in deterministic order through `sms_tool` using
only this fixed read-only allowlist:

```text
AT+CCID
AT+QCCID
AT+CIMI
```

The standard ICCID command is tried before the Quectel-compatible variant. A
port is accepted only when it returns one valid ICCID and one valid IMSI.
Symlinks outside the configured sysfs root, ports belonging to another USB
device, non-numeric suffixes and malformed modem output fail closed. No AT
command is accepted from UCI, the environment, the GUI or another caller.

It does not verify a PIN, change SIM power, register a network, edit a QMI
profile or start/stop a bearer. Connection ownership remains in OpenWrt netifd.

Successful identity output is root-owned TSV under the following v1 contract:

```text
v1
sim_index<TAB>1
modem_index<TAB>/dev/cdc-wdm0
iccid<TAB>digits
imsi<TAB>digits
eid<TAB>
operator_id<TAB>
operator_name<TAB>
gid1<TAB>
gid2<TAB>
modem_state<TAB>connected|enabled
registration_state<TAB>home|roaming|registered|idle|searching|denied|unknown
roaming<TAB>true|false|unknown
serving_operator_id<TAB>digits-or-empty
serving_operator_name<TAB>text-or-empty
access_technologies<TAB>text-or-empty
signal_quality<TAB>
```

Unknown values are empty instead of guessed. In particular, current `uqmi`
does not expose a reliable home operator through the operations used here. The
adapter therefore leaves `operator_id` empty, and the candidate matcher uses
the IMSI MCC/MNC prefix. A roaming serving PLMN is never presented as the SIM's
home operator.

Exit codes are:

- `0`: complete, valid identity contract;
- `1`: malformed input or response;
- `2`: invalid adapter invocation;
- `3`: dependency/device temporarily unavailable or a bounded command failed.

The core maps temporary identity failures to its retryable exit code 3.

## QMI profile write/apply

The QMI backend implements these operations as one rollback-safe unit:

1. read the complete profile fields owned by the backend;
2. validate a normalized candidate without shell evaluation;
3. persist the exact pre-change baseline atomically;
4. map the candidate to the backend's canonical netifd UCI options;
5. ask netifd to reconnect only the selected target;
6. expose the effective layer-3 device for common verification;
7. restore the exact previous profile and target state after every failure.

The core captures and restores exactly the owned QMI netifd options `apn`,
`username`, `password`, `auth` and `pdptype`. Normalized `pap-or-chap` maps to
uqmi's `both`; normalized IPv4 maps to qmi.sh's canonical `ip`. The baseline is
written atomically with mode constrained by `umask 077`, names the target and
backend, and is fully validated before reset performs its first UCI write.

Connection ownership remains in OpenWrt netifd. The adapter does not invoke
`--start-network`, `--stop-network` or `--modify-profile`; after UCI commit the
core asks netifd to restart only the selected target. If a requested
`ipv4v6` bearer does not become ready, QMI makes one explicit retry with IPv4
and records IPv4 as the effective cached profile when it succeeds. Other IP
families are not silently changed.

QMI does not inherit ModemManager's `allow_roaming` control. Until a portable,
tested QMI policy mapping exists, the GUI keeps that control visible but
disabled with an explanation, and the command fails with target-contract exit
code 4 without mutation. Status still reports the observed roaming state, but
uses `roaming_policy: "unsupported"`; APN operations ignore any stale
`network.<interface>.allow_roaming` value owned by another connection stack.
