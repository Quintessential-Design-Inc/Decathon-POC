# QUIN PRO / Decathlon Firmware POC

## Purpose and current status

This iPhone POC is intended to verify whether QUIN PRO / Decathlon helmet
firmware behaves as described in the integration guide. It must discover the
intended devices, connect, retrieve offline event data, preserve that data for
inspection and export, explicitly delete the sensor's offline data, and disconnect.

The user approved the implementation plan on 7 October 2026. This document records
that plan for future AI agents. At the time of writing, the app still contains the
starter SwiftUI screen; BLE and data handling have not been implemented or verified
on hardware. Creating this document does not itself authorize implementation.

## Instructions for future agents

- Follow the latest user request and any applicable `AGENTS.md` instructions.
- Do not create, modify, or suggest unit tests unless the user explicitly asks.
  Do not add test targets, test files, mocks, fixtures, or testing dependencies.
- Keep implementation focused on this POC. Optional additions below are separate
  scope and should not silently become mandatory features.
- Prefer the existing QuinKit products. Keep Decathlon protocol and data parsing
  in the app rather than adding product-specific behavior to QuinKitBLE.
- Preserve unrelated workspace edits. Do not change firmware configuration,
  calibration, device name, or timestamps through undocumented commands.
- Distinguish guide-derived behavior, source inspection, a successful build, and
  behavior observed on the physical helmet. None proves the others.
- Update this document when implementation decisions or verified firmware behavior
  materially change. Preserve the distinction between documented and observed facts.

## Sources and project setup

- Primary protocol source:
  [QUIN PRO (Decathlon) Mobile App Integration Guide.pdf](<Decathon POC/Firmware Doc/QUIN PRO (Decathlon) Mobile App Integration Guide.pdf>).
  The guide has 20 pages; relevant section numbers are included below.
- App entry point: `Decathon POC/Decathon_POCApp.swift`.
- Starter view: `Decathon POC/ContentView.swift`.
- Xcode project: `Decathon POC.xcodeproj`.
- The app already links `QuinKitBLE`, `QuinKitLogger`, and `QuinKitPermissions`.
- At review time, `Package.resolved` pins QuinKit-iOS `main` at
  `9deea2211df2667164d203d0e8f28f9955fab5f0`. Inspect the current resolved revision
  before relying on an API; the branch dependency can advance.
- At review time, the app target's minimum iOS version is 26.6. Align this with the
  physical POC phones before implementation; QuinKit's declared minimum is iOS 17.
- The app currently generates its Info.plist and has no
  `NSBluetoothAlwaysUsageDescription`. Add a suitable Bluetooth purpose string
  before using Bluetooth.

## Required user flow

1. Open the app and request Bluetooth permission if it is not determined.
2. Wait for Bluetooth to be powered on, then scan for matching Decathlon helmets.
3. Show device identity, battery percentage, and stored event count in scan results.
4. Connect to the peripheral explicitly selected by the user.
5. Navigate to a connected-device dashboard and prepare the notification channels.
6. Show device connection state, battery information, and available device details.
7. Retrieve offline events on button press, showing packet/event progress and
   approximate remaining time.
8. Persist the received data and make it available for inspection and export.
9. Offer an explicit action to delete all offline event data from the sensor.
10. Provide a disconnect button on the same dashboard.

The first implementation should use foreground retrieval. Temporarily prevent
automatic screen locking during transfer and restore the normal behavior afterward.
Do not promise continued transfer during backgrounding or app termination.

## QuinKit responsibilities

| Product | Use in this POC | App-owned work |
| --- | --- | --- |
| QuinKitBLE | Scan, connect, discover services/characteristics, read, write, notifications, disconnect | Device profile, manufacturer filtering, command routing, packet parsing, transfer state |
| QuinKitPermissions | Bluetooth authorization and Settings navigation | Permission UI and handling Bluetooth power separately from authorization |
| QuinKitLogger | Persistent diagnostic logs and CSV log export | Log meaningful commands, state transitions, transfer metrics, and failures |

Relevant reviewed APIs include `QKBLEManager`, `QKScanRequest`,
`QKAdvertisementData.manufacturerData`, `QKPeripheral.discoverServices`,
`discoverCharacteristics`, `notificationStream`, `setNotify`, `readValue`, and
`writeValue`. QuinKitBLE's permission facade delegates to QuinKitPermissions.

Register notification consumers before enabling notifications, await successful
notification setup, and only then send transfer commands. Keep the consumer alive
independently of transient SwiftUI view rendering.

QuinKitLogger is for diagnostics. Its retention-based log store must not be the
only permanent copy of retrieved event data.

## Screen 1: scanner

### Permission and scanning behavior

- Show distinct states for authorization pending, permission denied, Bluetooth off,
  scanning, no matches, and connection failure.
- Offer Settings navigation after permission denial and a Scan Again action.
- Display guidance to double-tap the helmet to make it discoverable.
- Match manufacturer data rather than the advertised name. The default name can
  appear truncated as `QuinPro080`.
- Allow duplicate discoveries to refresh an existing row rather than adding rows.
- Show last-seen information and handle expired advertisements/connection attempts.
- Stop scanning when connecting to the user's selected peripheral.

### Manufacturer data contract

Guide sections 2.2-2.4 describe a 14-byte manufacturer value including company ID.
QuinKit exposes CoreBluetooth's manufacturer data directly, so these offsets are
relative to that value, without the advertising length/type bytes:

| Offset | Length | Meaning |
| --- | --- | --- |
| 0-1 | 2 | Company ID `0x0ED6`, little-endian bytes `D6 0E` |
| 2-7 | 6 | Advertised device MAC/address bytes, most significant byte first |
| 8-11 | 4 | Required product signature `08 08 04 B3` |
| 12 | 1 | Battery percentage, valid range 0-100 |
| 13 | 1 | Stored offline event count, clamped to 255 |

Validate length before indexing. Reject nonmatching identities and handle malformed
fields without crashing or inventing a battery value. Use CoreBluetooth's peripheral
identifier for connection; the advertised MAC is useful device metadata.

Each result should show name/fallback identity, device address, battery percentage,
stored event count, RSSI, and last seen.

The advertised event count is a snapshot of stored records at advertising start.
It is not a live connected count and can include already transmitted records that
have not been erased. Label it accordingly.

## Screen 2: connected-device dashboard

- Show Connecting, Preparing, Ready, and Disconnected/Error states.
- Show identity, connection state, battery percentage/category, temperature,
  battery update time, and activity/inactivity when reported.
- Read model, serial number, and firmware/hardware version if corresponding Device
  Information characteristics are actually available.
- Keep advertised stored count separate from actual downloaded complete-event count.
- Provide Retrieve Offline Data, Export, Delete Offline Data, and Disconnect actions.
- Preserve access to saved downloads after a disconnect.

The guide exposes charge level and temperature, not battery capacity degradation,
cycle count, or a battery-health metric. Do not label charge percentage as health.

Battery strings on alert characteristic `0x1002` use
`<STATE>,<percent>,<temperature>`. Parse defensively and retain unknown text as
informational. Categories are FULL at >=90%, MEDIUM at 31-89%, and LOW at <=30%.
Reading the characteristic returns the last battery string. A forced reading is
documented about five seconds after connecting and on a double tap while connected.

## Connection preparation and protocol commands

Guide sections 3 and 11 require connection, service/characteristic discovery,
notification setup, and RTC setup. The RTC encoding is missing from the guide and
must be clarified before implementing that write.

| Characteristic shorthand | Write bytes | Operation | Completion |
| --- | --- | --- | --- |
| `0x6166` | `01` | Retrieve offline events | Event packets, then `01 33 55 AA` |
| `0x6166` | `02` | Erase the entire offline event partition | `01 33 55 AA` |
| `0x6166` | `03` | Retrieve battery/temperature log, optional | Log chunks, then `01 33 55 AA` |
| `0x6166` | `04` | Erase battery/temperature log, optional | `01 33 55 AA` |
| `0x1002` | `01` | Acknowledge crash and clear red crash LED, optional | No response documented |
| `0x1002` | `0A` | Get/sync extended IMU timestamp, optional | ASCII `TS:XXXXXXXX` |

Use the documented numeric command bytes. These are characteristic shorthands;
do not assume `CBUUID(string: "6166")` addresses the vendor's 128-bit characteristic.
Confirm complete service/characteristic UUIDs through the firmware profile and
discovery. Select write type according to discovered characteristic properties.

Enable notifications on both `0x6166` and `0x1002` before retrieval. The shared data
characteristic and shared end marker require exactly one active data operation.
An ATT write response means the write completed, not that replay or erase completed.

The guide requires ATT MTU >=129 for 126-byte event notifications. iOS negotiates
ATT MTU internally; there is no app-level Android-style request-MTU step. Verify
receipt of complete 126-byte packets on the target phone/firmware combination.
See [Apple's MTU explanation](https://developer.apple.com/forums/thread/824435).

## Offline retrieval, decoding, and progress

### Packet contract

Guide section 7 describes a complete event as 64 distinct 126-byte notifications,
or 8,064 bytes of BLE packet data:

| Bytes | Meaning |
| --- | --- |
| 0 | Frame number 1-64 |
| 1 | Sensor type: `01` IMU or `02` high-g |
| 2 | Packet/event type |
| 3-5 | Opaque 24-bit crash ID |
| 6-125 | 120 bytes of sample data |

Offline types include `43` fall, `53` crash after free-fall, and `63` impact. Online
packets use `11`. Preserve unknown types for diagnostics rather than silently
assigning a known classification. Do not invent major/minor severity from fields
that are not present in the offline BLE packet.

| Frames | Samples | Documented rate |
| --- | --- | --- |
| 1-30 | 300 pre-event IMU samples, 10 per packet | 104 Hz |
| 31-60 | 300 post-event IMU samples, 10 per packet | 52 Hz |
| 61-64 | 80 high-g samples, 20 per packet | Approximately 1 kHz |

Reassemble using device identity, crash ID, and frame number within a transfer.
Ignore identical duplicates, flag conflicting duplicates, and identify missing
frames. Crash IDs can collide; do not treat one 24-bit ID as a globally unique
lifetime key. Preserve a download/session identifier as well.

IMU samples contain little-endian int16 Gx/Gy/Gz/Ax/Ay/Az. Gyro scale is 0.07 degrees
per second per LSB; acceleration scale is 0.000488 g per LSB. The firmware already
adjusts axes/calibration; use values as delivered.

High-g samples contain Ix/Iy/Iz. Sign-extend the stored 12-bit value before applying
0.195 g per LSB: mask with `0x0FFF`, subtract `0x1000` when >=`0x0800`.
Early blank gyro samples can represent the inactive gyro's startup window; preserve
that qualification rather than interpreting them as confirmed zero rotation.

### Progress and timing

- Start with the last advertised count as an explicitly approximate denominator.
- Documented timings: about 2 seconds before the first packet, 120 ms between
  offline packets, and 200 ms between records.
- Initial estimate: `2 + eventCount * 64 * 0.12 + max(eventCount - 1, 0) * 0.2`
  seconds, approximately 80-85 seconds for 10 events.
- Update remaining time from observed packet spacing/throughput.
- Show complete events, current event's unique packet count, overall progress,
  elapsed time, and approximate remaining time.
- Adapt when the advertised count is unknown or differs from received data; do
  not force a misleading percentage.
- At the expected packet count, show Finalizing until the end marker and local
  persistence complete. An end marker alone only says the operation ended.
- Handle an immediate end marker as no downloadable records. It does not prove the
  sensor partition is empty because transmitted records can be skipped.
- Distinguish initial-response/stall timeouts from whole-transfer duration. A
  legitimate transfer can take longer than a normal characteristic operation.

## Persistence and export

- Persist received packets incrementally rather than waiting for the entire batch.
- Retain original packet bytes plus structured metadata and decoded samples.
- Metadata should include device identity, session ID, download time, crash ID,
  packet type, frame inventory, completeness, transfer duration, and diagnostics.
- Mark an event complete only after all 64 valid distinct frames and successful
  durable local saving. Check the saved record before permitting deletion.
- Preserve incomplete data as explicitly partial diagnostic records. Do not merge
  it into a later retrieval without verified firmware recovery behavior.
- Keep saved complete records after export failure, disconnection, or app relaunch.
- Do not use cache-only storage for the permanent original data.

Export a human-readable PDF report, decoded CSV, and original packet file. PDF
content should include device/firmware details when available, download time,
event IDs/types, completeness, transfer metrics, and calculated sensor summaries.
Use the iOS share sheet for export.

The original offline event timestamp is stored in flash but omitted from BLE event
packets. Label app timestamps as download/receive time. Relative sample timing is
possible using the documented rates; an original event date/time requires firmware
support. IMU timestamp sync cannot recover a missing per-event timestamp.

## Deletion and disconnection

- Deletion is a separate, explicit action after complete retrieval and verified
  saving. Never automatically delete on packet count, write success, or export.
- Explain that `02` on `0x6166` deletes the entire offline event partition; there is
  no documented per-event delete command.
- Disable deletion when data is incomplete, saving failed, or transfer reconciliation
  has unresolved errors.
- Wait for the operation's end marker before showing that firmware reports deletion
  complete. On timeout/disconnect, show an unknown result rather than success.
- A fresh advertisement with zero records provides an additional verification.
  Do not present the old advertised count as a fresh connected count.
- A new crash saved between retrieval and deletion may also be erased. The protocol
  has no documented transactional delete tied to the downloaded event IDs.
- Disable ordinary disconnect and competing commands while retrieval/erase is in
  progress. No safe cancel command is documented.
- After disconnection, explain that the helmet needs to advertise again before a
  new connection; offer wake/double-tap and scan guidance.

## Firmware constraints and unresolved points

| Item | Consequence / required action |
| --- | --- |
| Advertising lasts 20 seconds | Do not claim the feature-list target of 30 seconds is implemented. |
| No advertising at boot/wake or after disconnect | Double-tap guidance is required; blind reconnect cannot make a nonadvertising helmet discoverable. |
| Records are marked transmitted and skipped on later requests | Notification setup and incremental persistence are critical. Re-requesting is not guaranteed to recover lost data. |
| Mid-transfer disconnect state is not explicitly handled | Verify on hardware. Preserve saved data and flag incomplete retrieval; do not promise automatic resume. |
| Inactive after about 10 seconds; sleep about 50 seconds later | An idle connection can drop after roughly 60 seconds without motion. Transfers prevent sleep according to the guide. |
| Complete UUID catalog is not provided | Confirm the full vendor UUIDs; discover and validate the actual profile. |
| RTC `0x1003` write encoding is absent | Clarify length, byte order, epoch/representation, and clock units before writing. |
| Device clock is described as incrementing every millisecond despite a seconds label | Do not assign wall-clock semantics without firmware confirmation. |
| No original event timestamp in event packets | Export download time and relative sample timing; original date/time needs firmware changes. |
| No battery-health metric | Show charge, category, and temperature only. |
| Live diagnostic `0x6266` send routine is not called in the normal firmware loop | Exclude diagnostic live streaming from the initial POC. |
| Configuration/name writes reset the helmet | Keep them outside the initial required flow; reconnection needs user advertising action. |

Battery string formatting, sample rates, post-disconnect recovery, and physical LED
colors are explicitly identified by the guide as requiring hardware verification.
The guide also documents open characteristics without pairing/bonding; connection
to the selected identity is not proof of authenticated device ownership.

## Suggested implementation structure and phases

Use a small app-owned session coordinator with a Decathlon profile/decoder,
transfer/reassembly component, persistent download store, and report exporter.
SwiftUI screens should observe session state rather than own the transport lifetime.
Avoid unnecessary abstractions for a two-screen POC.

1. Confirm full UUIDs and RTC contract; align phone deployment target and add the
   Bluetooth usage description. Keep unresolved writes explicitly pending.
2. Implement permissions, scanner, advertisement parsing, selection, connection
   preparation, dashboard information, and disconnect.
3. Implement serialized offline retrieval, packet validation/reassembly, progress,
   incremental storage, and interruption/error states.
4. Implement raw/CSV/PDF export and explicit offline deletion with completion handling.
5. Build for the intended iPhone and manually verify the flow against physical
   firmware. Record observed results and limitations before claiming correctness.

Manual verification should cover permission denial, Bluetooth off, advertising
expiry, battery/count parsing, zero/one/multiple events, packet completeness,
measured duration, saved-file availability, export, erase completion, and reconnect.
Capture behavior during a deliberately controlled transfer interruption separately;
the firmware's recovery guarantees are not established by this plan.

## Optional additions

- Timestamped activity/command log visible in the dashboard.
- Transfer summary with measured packet spacing, duration, duplicates, missing
  frames, and saved bytes.
- Battery/temperature log retrieval and separate deletion via commands `03`/`04`.
  Log notifications contain whole 10-byte records and share `0x6166` with events.
- Crash LED acknowledgement through `01` on `0x1002`, clearly separate from deleting
  stored data through `02` on `0x6166`.
- Read-only configuration display, including offline/online crash mode.
- Foreground online crash handling after the offline flow is established, if the
  user asks. Online streams have no offline end marker and depend on configuration.

Optional features should not introduce automatic factory commands or configuration
writes. The documented default crash mode is offline-only (`01`); changing mode
requires a separate deliberate configuration operation and resets the device.
