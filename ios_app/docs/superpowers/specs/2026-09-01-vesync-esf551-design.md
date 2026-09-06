# VeSync ESF551 Support Design

## Goal

Add full, local support for the Etekcity VeSync ESF551 body-composition scale to
JarvisWearables. The app must scan, connect, receive live and stored readings,
calculate body metrics, retain history, expose controls, and make the data available
to JarvisCopilot.

## Scope

This implementation targets the physical ESF551 family first. The discovery and
transport abstractions must retain the protocol-family boundary needed for later
VeSync scales, but no unverified model may appear as supported.

## Reverse-engineered protocol

The Android VeSync 5.9.60 app maps ESF551 variants to `BT_SCL_ESF551_US` and
`BT_SCL_ESF551_EU`. Its VsV2 transport accepts either of these GATT profiles:

| Role | Primary UUID | Alternate UUID |
| --- | --- | --- |
| Service | `FFF0` | `FFE0` |
| Write | `FFF1` | `FFE1` |
| Notify | `FFF2` | `FFE2` |

Packets use the envelope `A5 flags sequence lengthLE checksum channel commandLE
subcommand payload`. ESF551 live-measurement notifications have command `0xA161` and
a payload beginning at byte 10: three-byte little-endian raw weight, two-byte
little-endian impedance, four-byte little-endian Unix timestamp, stable flag,
impedance-enabled flag, then unit. The reference client normalizes the raw value to
kilograms before persistence.

The stock client exposes live and saved readings, profiles, athlete and visitor modes,
unit changes, zero mode, continuous measurement, body composition, and history.

## Architecture

`ScaleProtocol` owns BLE UUIDs, frame parsing, the ESF551 reading decoder, and control
packet construction. `ScaleManager` owns CoreBluetooth scanning, connection,
notifications, the latest reading, and conversion of stable readings into persistent
`ScaleReading` values. It is the only component that touches CoreBluetooth.

`ScaleMetricsCalculator` receives an already-normalized weight, impedance, and user
profile and returns only deterministic derived metrics. `ScaleHistoryStore` remains the
local source of truth for readings and profiles. `Esf551Scale` adapts the manager to the
existing `WearableDevice` interface, supplying only safe, meaningful Jarvis skills.

`ScaleDeviceView` renders the current measurement, all available metrics, history,
profiles, and ESF551 controls. `ScanView` presents bottles and scales through their
separate managers while preserving the current bottle experience.

## Data flow

1. The scan manager recognizes an ESF551 advertisement and exposes it as a scale.
2. The manager discovers the primary or alternate GATT profile, enables notifications,
   and validates VsV2 frames.
3. A live frame becomes a `ScaleObservation`; unstable observations update the display,
   and a new stable observation becomes a persisted `ScaleReading`.
4. A profile plus impedance enables derived metrics. Weight and BMI remain available
   without impedance.
5. The device adapter publishes read-only health data, history, unit selection, zero,
   and continuous-measurement operations to the existing Jarvis bridge.

## Error handling and safety

Malformed, incomplete, checksum-invalid, or non-ESF551 packets are discarded. Repeated
stable readings are de-duplicated. The app never sends an unverified control packet to
the scale; the first implementation supports only commands whose behavior was recovered
from the APK. Health metrics are labeled estimates and do not present medical advice.

## Testing

Unit tests cover frame validation, frame parsing, unit conversion, stable-reading
deduplication, body-metric calculation, and history persistence. A device build on the
physical ESF551 validates discovery, both live and stable readings, and UI integration.
