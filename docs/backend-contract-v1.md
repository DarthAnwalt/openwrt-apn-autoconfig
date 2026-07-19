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
`mmcli` or `uqmi` makes the corresponding capability false without hiding the
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
It invokes only bounded, read-only `uqmi` operations:

```text
--get-iccid
--get-imsi
--get-serving-system
```

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

The core maps temporary identity failures to its retryable exit code 3. QMI
profile mutations remain unavailable and use the target-contract exit code 4
before UCI, persistent state, `ifdown` or `ifup` can be reached.

## Future write/apply operations

A backend may advertise profile mutation only after it implements all of these
operations as one rollback-safe unit:

1. read the complete profile fields owned by the backend;
2. validate a normalized candidate without shell evaluation;
3. persist the exact pre-change baseline atomically;
4. map the candidate to the backend's canonical netifd UCI options;
5. ask netifd to reconnect only the selected target;
6. expose the effective layer-3 device for common verification;
7. restore the exact previous profile and target state after every failure.

The QMI alpha deliberately stops before this boundary. Hardware observations
may change QMI option mapping without changing the common APN engine.
