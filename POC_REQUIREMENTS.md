# QUIN PRO / Decathlon Firmware POC

## Purpose and current status

This iPhone POC is intended to verify whether QUIN PRO / Decathlon helmet
firmware behaves as described in the integration guide. It must discover the
intended devices, connect, retrieve offline event data, preserve that data for
inspection and export, explicitly delete the sensor's offline data, and disconnect.

The user approved the implementation plan on 7 October 2026 and then requested
development in ten steps, one at a time, so requirements can change between steps.
Steps 1-4 are implemented: Bluetooth purpose string and primary color, branded home
screen with a fixed logo header, app-owned QuinKit BLE permission/availability
session with logging, and Decathlon-filtered scanning on a separate screen opened
by the home Scan button. The user requested steps 2
and 3 together, then authorized step 4 after restricting scan rows to name, MAC,
battery, and event count. Physical helmet discovery has not been verified.
Connection, event retrieval, and export remain planned in steps 5-10.

## Instructions for future agents

- Follow the latest user request and any applicable `AGENTS.md` instructions.
- Implement only the currently requested step. After each step, explain what
  changed, why it changed, verification performed, and notes/focus areas for the
  user. Wait for the user's next instruction before starting another step.
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
- Home view: `Decathon POC/ContentView.swift`.
- Dedicated scanner view: `Decathon POC/UI/HelmetScannerView.swift`.
- App-owned BLE session: `Decathon POC/Core/BluetoothSession.swift`.
- Manufacturer parser and discovery model: `Decathon POC/Core/DiscoveredHelmet.swift`.
- Four-field result row: `Decathon POC/UI/HelmetScanResultRow.swift`.
- Shared native glass action: `Decathon POC/UI/POCActionButton.swift`.
- Xcode project: `Decathon POC.xcodeproj`.
- The app already links `QuinKitBLE`, `QuinKitLogger`, and `QuinKitPermissions`.
- At review time, `Package.resolved` pins QuinKit-iOS `main` at
  `9deea2211df2667164d203d0e8f28f9955fab5f0`. Inspect the current resolved revision
  before relying on an API; the branch dependency can advance.
- At review time, the app target's minimum iOS version is 26.6. Align this with the
  physical POC phones before implementation; QuinKit's declared minimum is iOS 17.
- The app generates its Info.plist. Step 1 adds
  `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription` to Debug and Release with:
  "Bluetooth is used to connect to your QUIN PRO helmet and retrieve its offline
  event data." Do not introduce a separate Info.plist while generation is enabled.
- `AccentColor` is the single source for primary brand color `#00C8DC` in sRGB.
  The app applies this color as its root tint.
- The user supplied `QuinLogo` as a vector PDF image asset. The home screen preserves
  the original artwork and places it in a fixed top-left header. The current header
  has no dark backing or trailing label; preserve the user's styling edits.

## Visual direction

- Use primary color `#00C8DC` for prominent actions, selected states, and progress.
- Use the existing `QuinLogo` asset at the top-left of the home screen. Centered
  placement remains possible if requested. Preserve its aspect ratio and artwork.
- Keep the logo header outside the scroll view. Only the introduction, Bluetooth
  status, helmet guidance, and discovery action below the header should scroll.
- Keep the home Scan for Helmets button at the bottom of that content, after helmet
  guidance. It navigates to a separate scanner screen; do not put scan status or
  discovered device rows back on Home. The scanner uses native navigation/back
  controls and a bottom Stop Scanning / Scan Again action.
- Prefer native Liquid Glass controls, including SwiftUI `.glass` and
  `.glassProminent` button styles where appropriate. Use system navigation and
  sheets; use custom `glassEffect` only when it improves a specific control.
- Keep device readings, event lists, and diagnostic text readable on normal content
  surfaces. Avoid layering glass on every data card or on other glass surfaces.
- Support Dynamic Type, VoiceOver, light/dark appearance, and system accessibility
  settings. Check text contrast against cyan rather than assuming white is legible.
- If the minimum iOS version is lowered below Liquid Glass availability, add
  appropriate availability handling rather than using unsupported APIs.
- Reference: [Apple's Liquid Glass guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).

## Required user flow

1. Open the app and request Bluetooth permission if it is not determined.
2. Tap Scan for Helmets at the bottom of Home to open the separate scanner screen.
3. When permission and Bluetooth power are ready, scan for matching Decathlon helmets
   and show name, MAC, battery percentage, and stored event count on that screen.
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

### Implemented permission/session behavior (step 3)

- `Decathon_POCApp` owns one `BluetoothSession` in SwiftUI `@State`. Screen updates
  do not recreate the session or its transport.
- Logger setup happens at app startup: console plus local persistence, seven-day
  retention. It records app startup, permission requests/changes, transport creation,
  Bluetooth availability changes, Settings navigation, and return-to-active refreshes.
- Startup requests permission through `QKPermissions.request(.bluetooth)` only when
  status is not determined. A start guard and pending-request guard prevent duplicate
  requests; a denial does not repeatedly trigger prompts.
- After authorization is granted, the session creates one `QKBLEManager`, with no
  background restoration, no automatic reconnect, one simultaneous connection,
  and no extra system power alert.
- QuinKitBLE delegate callbacks update the observable Bluetooth availability state.
  Permission and power are separate; readiness requires authorization plus powered-on.
- Returning to the active scene refreshes authorization and availability, including
  after Settings. Step 4 starts discovery only while the dedicated scanner screen
  is visible and foreground Bluetooth readiness is confirmed; no connection or
  firmware command is performed.
- The home screen has actionable Allow Bluetooth / Open Settings controls when
  appropriate and power-off guidance with a manual refresh action. Request-pending,
  unknown, resetting, unsupported, powered-off, denied, and ready states are distinct.
- The home Scan button opens the scanner even when Bluetooth is unavailable, so its
  access/readiness explanation can be viewed. Actual scanner start/stop/retry controls
  remain readiness-gated; navigating to the screen does not bypass Bluetooth checks.

## Screens 1 and 2: Home and scanner

### Permission and scanning behavior

- Show distinct states for authorization pending, permission denied, Bluetooth off,
  scanning, no matches, and connection failure.
- Offer Settings navigation after permission denial and a Scan Again action.
- Display guidance to double-tap the helmet to make it discoverable.
- Match manufacturer data rather than the advertised name. The default name can
  appear truncated as `QuinPro080`.
- Allow duplicate discoveries to refresh an existing row rather than adding rows.
- Keep last-seen metadata internal and handle expired advertisements. Connection
  attempts belong to step 5.
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

Each result should show only device name/fallback name, advertised MAC address,
battery percentage, and stored event count. The user explicitly removed RSSI from
step 4; do not show signal strength or last-seen timestamps in the result row.
Maintain last-seen metadata internally for stale-result handling.

For this POC, identify the documented Decathlon helmet profile by BOTH company ID
`0x0ED6` at offsets 0-1 and the complete `08 08 04 B3` signature at offsets 8-11.
Company ID alone is not enough to distinguish this product. The signature denotes
Decathlon, snowboarding, helmet, and the documented hardware/storage capabilities.
Reject absent or truncated manufacturer data before indexing. Match by these
bytes even when the advertised name is absent, shortened, or changed.

Use QuinKitBLE discovery results and apply this manufacturer filter in the app;
the existing QuinKit scan filter provides names/RSSI, not a company-ID criterion.
Start with no name/service restriction so identity is decided by manufacturer data.
RSSI must not be used as the Decathlon identity criterion.

Format manufacturer bytes 2-7 as a colon-separated MAC address in their delivered
order, for example `AA:BB:CC:DD:EE:FF`. This is the address embedded by the firmware,
not a MAC obtained from CoreBluetooth's peripheral identifier. Keep the identifier
internally for deduplication and future connection.

The advertised event count is a snapshot of stored records at advertising start.
It is not a live connected count and can include already transmitted records that
have not been erased. Label it accordingly.

### Implemented scanning behavior (step 4)

- Home does not scan automatically. Tapping its bottom Scan for Helmets button
  pushes `HelmetScannerView`; entry requests a fresh scan when foreground Bluetooth
  is ready, or waits for readiness on that screen. Each scan lasts 30 seconds; this
  does not change the firmware's approximately 20-second advertising window.
- The scanner's native glass action switches between Scan for Helmets, Stop Scanning,
  and Scan Again. Starting a new scan clears the previous snapshot. Leaving the
  scanner stops discovery, clears results, and prevents automatic restart on Home.
- QuinKit receives broad discovery requests with no service or name restriction,
  duplicates enabled, and `minimumRSSI: Int.min` to avoid a signal-strength cutoff.
  The app accepts only company `0x0ED6` plus signature `08 08 04 B3`.
- Parse only manufacturer values of at least 14 bytes. A matching identity with a
  battery byte above 100 displays Unavailable instead of an invented percentage.
- Deduplicate by CoreBluetooth peripheral ID, preserve discovery order, and refresh
  the same row's name, MAC, battery, event count, and internal last-seen metadata.
- While scanning, remove rows with no matching advertisement for 10 seconds. This
  is a UI freshness heuristic, not proof the helmet disconnected or went to sleep.
- On stop/timeout, retain rows as explicitly labeled last-scan snapshots. A new
  scan, backgrounding, or lost Bluetooth availability clears obsolete rows.
- Scanning is foreground-only. An active scan interrupted by backgrounding or lost
  Bluetooth availability can restart when foreground readiness returns while the
  scanner remains visible. A manual stop or completed scan does not continuously
  restart. Reopening the scanner starts a new discovery session.
- Guard pending scan startup and late stop callbacks so duplicate tasks and native
  power-state transitions do not incorrectly complete or replace a newer scan.
- Log scan start, stop, completion, interruptions, discovery, and failures through
  QuinKitLogger. Result rows are informational; connection is deferred to step 5.

## Screen 3: connected-device dashboard

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

## Implementation structure and ten-step plan

Use a small app-owned session coordinator with a Decathlon profile/decoder,
transfer/reassembly component, persistent download store, and report exporter.
SwiftUI screens should observe session state rather than own the transport lifetime.
Avoid unnecessary abstractions for the home, scanner, and connected-device screens.

| Step | Status | Changes / deliverable | Why | User focus / notes |
| --- | --- | --- | --- | --- |
| 1. Project foundation | Implemented | Bluetooth purpose string in generated Info.plist for Debug/Release; `#00C8DC` AccentColor; root tint; recorded logo and Liquid Glass direction | Prepare Bluetooth access and a consistent brand color | Purpose string does not request permission by itself. Logo placement and glass controls arrive in step 2. Confirm intended iPhone OS before changing deployment target. |
| 2. Home screen and visual foundation | Implemented | Branded home layout, fixed top-left Quin logo header with scrolling content below, helmet guidance, native glass action component, and readable status surface | Establish the interface and keep branding visible while scrolling | Review logo placement, spacing, contrast, light/dark mode, and larger text. No fabricated readings are shown. Step 4 wires the discovery control. |
| 3. BLE session, permissions, and diagnostics | Implemented | App-owned long-lived QuinKitBLE session; permission/power states; Settings action; return-from-Settings refresh; persistent QuinKitLogger configuration | Centralize transport ownership and distinguish denied access from Bluetooth being off | Check first-launch prompt, denial, power changes, and lifecycle behavior on a physical iPhone. Step 4 adds readiness-gated scanning; connection and firmware commands remain pending. |
| 4. Scan and discover Decathlon devices | Implemented | Home's bottom Scan button opens a separate scanner; match company `0x0ED6` plus signature `08 08 04 B3`; rows show only name, MAC, battery, and stored events; start on scanner entry and provide stop/retry controls | Keep discovery on its own screen and identify the documented Decathlon helmet profile without connecting | No RSSI display or cutoff. Keep last-seen data internal. Stop scanning on leaving the scanner. Consider advertising window, malformed data, stale/duplicate rows, and count snapshots. Physical discovery remains unverified. |
| 5. Connect and prepare the profile | Planned | Selected-device connection; discover/validate full vendor UUIDs and properties; register consumers; await notification setup; connection/preparation failures | Ensure the data path is ready before any replay command | Confirm full UUIDs and actual 126-byte notification delivery on hardware. Resolve RTC format; leave undocumented RTC writes pending and visible rather than guessing. |
| 6. Connected dashboard and disconnect | Planned | Connected identity, battery/category/temperature/update time, activity, available Device Information, count labels, and disconnect | Expose sensor state and user control on one screen | No invented battery-health value or fresh-count claim. Observe idle sleep and re-advertising after disconnect. Retrieval/export/delete controls stay unavailable until their steps are implemented; later busy states must prevent mid-transfer disconnect. |
| 7. Retrieve, decode, and preserve offline packets | Planned | Serialized `01` replay; raw packet journal persisted during reception; packet validation, event reassembly, duplicate/missing-frame tracking, decoder, end-marker handling | Retrieve events while preserving evidence immediately | Persistence is part of this step, not deferred to export. Check 64-frame completeness, signed high-g decoding, skipped transmitted records, and partial-transfer handling. Do not enable deletion yet. |
| 8. Progress, saved downloads, and recovery UX | Planned | Event/packet progress, adaptive ETA, elapsed time, finalization and verified complete archives, saved-download access, timeout/error states, foreground screen-lock handling, busy guards | Make long downloads understandable and distinguish receipt from durable success | Approximately 80-85 seconds initially for ten events; count can be stale. Handle zero data, lost links, backgrounding, disk errors, and relaunch without promising firmware resume. Preserve complete data and clearly identify partial data. |
| 9. PDF, CSV, and raw export | Planned | Reports and decoded sample export generated from saved records; original packet export; share sheet; export failure/retry | Make firmware results reviewable outside the app | Label download time accurately; original offline event date/time is missing from packets. Export must remain available after disconnect and must never delete sensor data. |
| 10. Explicit deletion and end-to-end device review | Planned | Separate confirmed `02` erase after verified saving; wait for erase completion marker; unknown-result handling; fresh-scan verification; complete manual device walkthrough | Finish the requested lifecycle while preventing accidental loss of unsaved data | Entire partition is erased, including possible new events. A write response is not erase completion. Record actual hardware observations, recovery limits, and build/visual verification separately. |

### Per-step delivery expectations

For every implemented step, provide the user with:

1. What changed: concrete behavior and relevant files.
2. Why: the requirement or firmware constraint addressed.
3. Verification: appropriate build/source checks and any manual observations;
   state clearly what remains unverified. Do not add unit tests.
4. Notes and focus areas: UI choices, hardware actions, edge cases, or protocol
   questions the user should review before the next step.

The ten-step plan is adjustable between steps. Carry forward accepted user changes
in this document instead of proceeding automatically through the remaining steps.

### Step 1 verification (7 October 2026)

- Debug simulator build passed with Xcode 27.0 and the resolved QuinKit dependency,
  using a generic iOS Simulator destination and disabled code signing.
- Inspected the generated app Info.plist and confirmed the exact Bluetooth purpose
  string. Both Debug and Release project configurations contain the key; a Release
  build was not run.
- Asset catalog compilation succeeded, including the `#00C8DC` AccentColor and
  existing Quin logo. Root SwiftUI tint compiled successfully.
- Project plist syntax and `git diff --check` passed.
- The sandboxed build initially failed on Xcode/SwiftPM cache and simulator-service
  access; rerunning the same build with the required access succeeded.
- No runtime permission prompt, physical BLE behavior, or visual appearance was
  verified in this step. No unit tests were added or run.

### Steps 2 and 3 verification (7 October 2026)

- Final Debug simulator build passed with Xcode 27.0 and the existing resolved
  QuinKit dependency. `git diff --check` passed.
- Launched the actual app on the iOS 27 iPhone 17 Pro Max simulator and inspected
  light/dark appearance and accessibility-large text. Status rows adapt vertically,
  text wraps, the content scrolls, and the disabled native glass action remains
  distinguishable. Original simulator appearance/text settings were restored.
- Observed the native unsupported-Bluetooth state with permission reported as
  granted; the app displayed availability separately rather than claiming readiness.
- Confirmed startup, transport creation, Bluetooth availability, and foreground
  refresh entries persisted in QuinKitLogger's SQLite store. Reactivation after
  visiting Settings used the existing session rather than creating another transport.
- Actual first-launch Bluetooth prompt, denial/restricted access, permission changes
  in app Settings, and powered-off/on transitions still require a physical iPhone.
  The simulator observation does not establish helmet discovery or connectivity.
- VoiceOver labels/grouping are implemented but were not verified through a
  VoiceOver walkthrough. No unit tests were added or run.

### Step 4 verification (7 October 2026)

- Debug simulator build passed with the existing QuinKit dependency; `git diff
  --check` passed. The manufacturer parser, scan lifecycle, and result row compiled.
- Launched the actual app on the iOS 27 iPhone 17 Pro Max simulator. The fixed header,
  nearby-helmets section, readiness explanation, and disabled scan action rendered
  in the native unsupported-Bluetooth state.
- No real advertisement, populated result row, 30-second scan completion, duplicate
  refresh, stale expiry, or active-scan interruption was observed on hardware.
  Those behaviors are implemented but require an iPhone and matching helmet.
- No fabricated sensor results, mock advertisements, or unit tests were added.

### Separate scanner navigation follow-up (7 October 2026)

- Moved scanning status, readiness handling, device rows, and scan controls into
  `HelmetScannerView`. Home's Scan button follows helmet guidance and opens that
  screen; the Quin logo stays fixed above the home scroll content.
- Discovery requires scanner visibility as well as foreground Bluetooth readiness.
  Screen entry initiates scanning when ready. Screen departure stops scanning and
  clears results; returning to Home cannot silently resume discovery.
- Debug simulator build and `git diff --check` passed. Pressed the actual home Scan
  button in Device Hub and observed navigation to Nearby Helmets, native Back,
  unsupported-Bluetooth guidance, and its disabled bottom scan control.
- Physical discovery and stopping an active scan on Back remain hardware checks.

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
