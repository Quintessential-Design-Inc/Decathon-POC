# QUIN PRO / Decathlon Firmware POC

## Purpose and current scope

This iPhone POC checks QUIN PRO / Decathlon helmet firmware against the integration
guide. The current flow is **connect → retrieve → export CSV → optionally delete
from the helmet → disconnect**.

The latest user instruction on 7 October 2026 replaces the earlier persistent
storage, saved downloads, archive recovery, PDF report, and raw-file export plan:

> Each connection session stands alone. Keep retrieved data in memory; when the
> user taps Export, convert it to CSV and share it. Offer deletion from the BLE
> device. Do not save downloads in the app.

This instruction is authoritative. Do not reintroduce saved-download screens,
local archives, journals, database storage of crash samples, recovery on relaunch,
PDF export, or automatic export/deletion. Steps 1–8 are implemented with this scope
change; CSV sharing and manual helmet deletion are also implemented as part of the
latest request. Physical replay, CSV sharing, and erase verification remain pending.
The user reported that connection works on hardware; the agent has not observed it.

## Instructions for future agents

- Follow the latest user request and applicable `AGENTS.md` instructions.
- Develop changes one step at a time unless the user explicitly bundles them.
  Explain what changed, why, verification performed, and relevant notes afterward.
- Do not create, modify, or suggest unit tests unless explicitly requested. Do not
  add test targets, files, mocks, fixtures, or testing dependencies.
- Preserve unrelated workspace edits. Commit only when the user requests it.
- Use QuinKitBLE, QuinKitPermissions, and QuinKitLogger where appropriate. Keep
  Decathlon filtering, protocol parsing, and operation state in the app.
- Keep crash data volatile and export on demand. Do not silently expand scope.
- Do not write configuration, calibration, device name, or RTC settings as part of
  this flow. Implemented commands are retrieve `01` and erase `02` on data,
  IMU reset `09` / sync `0A` on alerts, and the explicitly requested RGB `0B`
  command on alerts. Colour changes require the user to tap Set LED colour.
- Distinguish guide facts, inspected source, successful builds, user-reported
  behavior, and directly observed hardware behavior. One does not prove another.
- Update this document when the user changes requirements or hardware evidence
  materially changes a protocol assumption.

## Sources, setup, and ownership

Primary source: [QUIN PRO (Decathlon) Mobile App Integration Guide 2.pdf](<Decathon POC/Firmware Doc/QUIN PRO (Decathlon) Mobile App Integration Guide 2.pdf>),
21 pages. Advertising is in section 2, connection in section 3, event packets in
section 7, and the recommended app sequence in section 11.

| File | Responsibility |
| --- | --- |
| `Decathon POC/Decathon_POCApp.swift` | App-owned session, root tint, console-only logger configuration, scene lifecycle |
| `Decathon POC/ContentView.swift` | Fixed logo header, scrollable Home content, bottom Scan action |
| `Decathon POC/Core/BluetoothSession.swift` | Permission/readiness, scanner lifecycle, QuinKit manager ownership |
| `Decathon POC/Core/DiscoveredHelmet.swift` | Manufacturer identity parsing and discovery model |
| `Decathon POC/UI/HelmetScannerView.swift` | Dedicated scanner and connection navigation |
| `Decathon POC/UI/HelmetScanResultRow.swift` | Device name, MAC, battery, stored-event count, Connect |
| `Decathon POC/Core/DecathlonProfile.swift` | Resolve actual discovered UUIDs and validate capabilities |
| `Decathon POC/Core/HelmetConnection.swift` | Connection preparation, notification consumers, dashboard reads, operation guards |
| `Decathon POC/Core/HelmetIMUClock.swift` | IMU synchronization, manual reset verification, and event time mapping |
| `Decathon POC/Core/HelmetLEDColor.swift` | RGB validation, four-byte command encoding, serialized reply handling and cancellation |
| `Decathon POC/Core/HelmetReadings.swift` | Battery, temperature, activity, configuration, Device Information parsing |
| `Decathon POC/UI/HelmetConnectionView.swift` | Connected dashboard and Disconnect |
| `Decathon POC/UI/LEDColorCard.swift` | Three RGB number fields, Set LED colour, validation and command result |
| `Decathon POC/Core/OfflineRetrieval.swift` | In-memory retrieval, progress, timeouts, erase confirmation, session cleanup |
| `Decathon POC/Core/CrashPacket.swift` | Packet validation, record assembly, physical-unit sample decoding |
| `Decathon POC/Core/SessionCSVExporter.swift` | Generate decoded CSV in memory on demand, away from the UI actor |
| `Decathon POC/UI/CSVShareSheet.swift` | Native share sheet with an in-memory CSV item provider |
| `Decathon POC/UI/OfflineRetrievalCard.swift` | Retrieve/progress, session event details, Export CSV, manual IMU reset, confirmed Delete |
| `Decathon POC/UI/POCActionButton.swift` | Shared native glass action styling |

The app links QuinKitBLE, QuinKitPermissions, and QuinKitLogger. Reviewed package
revision: `9deea2211df2667164d203d0e8f28f9955fab5f0` on QuinKit-iOS `main`; verify
`Package.resolved` before assuming newer SDK behavior. The target currently requires
iOS 26.6. Shared off-main data models use `nonisolated`/`Sendable` because the project
has MainActor default isolation.

The Info.plist is generated. Debug and Release contain
`INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`:
"Bluetooth is used to connect to your QUIN PRO helmet and retrieve its offline
event data." The purpose string alone does not request permission.

QuinKitLogger is configured with `persistLogs: false`. App diagnostics go to the
console; crash data is not a log-backed archive. The pinned logger can initialize
its default internal store before configuration; disabling destinations is not a
promise that SDK/OS internals create no files. Old archives from earlier installed
versions are no longer read or written; no destructive migration has been added.

## Visual requirements

- Primary color is `#00C8DC`, defined once in `AccentColor` and applied as root tint.
- Preserve the supplied vector PDF `QuinLogo`, fixed at the top-left of Home with
  scrolling content below it. Preserve the user's removal of the dark backing and
  trailing QUIN PRO label.
- Home's Scan for Helmets action follows the helmet guidance at the bottom of its
  content and opens a separate scanner. Keep scan status and results on that screen.
- Use native Liquid Glass actions and system navigation/sheets. Keep data cards
  readable; support larger text, VoiceOver, and light/dark appearance.
- The scanner has a bottom Scan / Stop / Scan Again action. The dashboard has a
  bottom Cancel Connection / Disconnect action.

## Permission and discovery

The app owns one long-lived BluetoothSession. Request Bluetooth permission through
QuinKitPermissions only when not determined, avoid duplicate prompts, provide
Settings navigation after denial, and refresh on return. Bluetooth power and app
permission are separate states. No background restoration or automatic reconnect
is configured; allow one simultaneous connection.

Home does not scan automatically. Scanner entry starts when foreground Bluetooth
is ready. Use a broad QuinKitBLE scan without name/service restrictions or RSSI
cutoff, then filter manufacturer bytes in the app. Scan for 30 seconds; the helmet
advertises for about 20 seconds after a double tap. Boot, wake, and disconnect do
not automatically start advertising. Give wake/double-tap/re-scan guidance.

Manufacturer data offsets include the company ID, without advertising length/type:

| Offset | Meaning |
| --- | --- |
| 0–1 | Company ID `0x0ED6`, little-endian bytes `D6 0E` |
| 2–7 | MAC/address bytes, format in delivered order as uppercase colon-separated hex |
| 8–11 | Required product signature `08 08 04 B3` |
| 12 | Battery percentage 0–100; show Unavailable for an invalid value |
| 13 | Stored offline event count, clamped to 255 |

Require at least 14 bytes, **both** company ID and full signature. Company ID or
name alone does not identify Decathlon. Connect using CoreBluetooth's peripheral
identifier; the embedded MAC is metadata, not an iOS-derived peripheral address.

Rows show name/fallback, MAC, battery, and stored events. Do not show RSSI or current
g threshold: the advertisement does not include threshold settings. Deduplicate
by peripheral ID, preserve discovery order, and refresh matching rows. During a
scan, expire rows not seen for 10 seconds (a UI heuristic). Stopped results are
labelled snapshots; new scans, scanner departure, backgrounding, and unavailable
Bluetooth clear stale results. Manual stops do not continuously restart scanning.

The event count is a snapshot at advertising start, can include transmitted records,
and is not a live connected count. Do not overwrite it with a guessed zero after
retrieval or deletion.

## Connection preparation and dashboard

Stop scanning and connect to the explicitly selected peripheral (15-second app
connection timeout). Discover services and characteristics sequentially; discovery
and subscription operations use 10-second timeouts. Resolve roles from full
**discovered** UUIDs because the PDF does not supply a complete vendor catalog:

- Unique 128-bit data service with prefix `8925D23D-`; resolve shorthand `6166` there.
- Resolve alerts `1002` across discovered 128-bit vendor services.
- Match literal 16-bit characteristic codes or the low 16 bits of the first field
  of a 128-bit UUID. Reject missing/ambiguous matches; do not fabricate a vendor base.
- Data requires write and value updates; alerts require read, write, and updates.
  Accept notify/indicate; prefer data writes with response when supported.
- Register both notification consumers **before** enabling either CCCD. Await
  `setNotify`, verify actual `isNotifying`, then declare the connection ready.

Keep consumers owned by HelmetConnection, independent of view rendering. Invalidated
attempt IDs reject late callbacks. Cancel/Back, preparation/stream failures,
Bluetooth loss, and backgrounding close the connection. No blind reconnect.

After preparation, read alerts once, read configuration once, then available Device
Information fields sequentially, with five-second timeouts and no polling. Optional
read failures do not invalidate otherwise working notification channels. Display:

- Device name, MAC, connection state, battery charge/category and sensor temperature.
- Advertised Stored Events at Scan, distinct from received complete-event count.
- Read-only major/minor crash thresholds from configuration `1001` in the alert
  service: exactly 10 bytes, major g at byte 1, minor g at byte 2, mode at byte 9.
  Documented defaults are 80/20 g; display read values rather than assumed defaults.
- Activity ACT/INACT when reported, and Device Information service `180A` fields:
  firmware `2A26`, hardware `2A27`, model `2A24`, serial `2A25`, when uniquely readable.
- Collapsible UUID/property/subscription diagnostics and notification counts.

Alerts `1002` carry text: `FULL BATTERY`, `MEDIUM BATTERY`, or `LOW BATTERY` followed
by percentage and temperature; ACT/INACT; or ten-value `Temp:` batches (display the
last value). Parse complete finite valid messages; unknown text remains diagnostics.
A read returns cached battery status. The guide describes a forced battery update
about five seconds after connection and on a double tap while connected. App receipt
times are not sensor measurement times; a read must not overwrite a newer notification.

Battery health/capacity degradation is not exposed. Historical dashboard readings
can remain visible in RAM after disconnect with an explicit label, and reset on the
next connection. Retrieved crash records themselves are cleared immediately.
Configuration/name writes reset the helmet; this app only reads configuration.

## LED colour control

The updated guide section 3.4 documents the testing-only colour command on the
discovered alert characteristic (`1002`). Send exactly four numeric bytes:
`0B R G B`. Each channel is 0–100, as confirmed by the user. Do not scale to
0–255 or encode ASCII numbers. For R=100, G=25, B=0, send `0B 64 19 00`.
Sending `0B 00 00 00` clears colour without acknowledging or clearing crash/SOS
flags. Do not send the separate alert `01` acknowledgement automatically.

The connected dashboard has a separate LED colour card after Battery, with Red,
Green and Blue number-pad fields initially set to 0, a keyboard Done action,
and Set LED colour. Trim surrounding whitespace and accept ASCII whole numbers
only, including endpoints 0 and 100. Reject empty, negative, decimal and
out-of-range values before sending. Do not silently clamp input. Draft inputs
and status are not persisted, and no command is sent on connection or editing.

`HelmetLEDColor` arms response handling before transport writes, retains an early
reply until the write settles, and accepts only `RGB,r,g,b` matching the requested
values or `RGB,CHG`. The latter means the command was ignored while charging.
Unrelated battery/activity/TS notifications remain available to their handlers.
Use the profile's supported write type and a five-second write/response timeout;
a BLE write acknowledgement alone does not confirm the colour. Timeout or a
malformed reply produces an unconfirmed result, with no automatic retry. Keep
competing controls blocked until an in-flight BLE write also settles.

Disable colour editing/sending during connection preparation, initial dashboard
reads, retrieval, erase, clock synchronization/reset, CSV generation/sharing,
or another colour request. Disable retrieval, reset, erase, export and user
Back/Disconnect while sending. Backgrounding, Bluetooth loss or disconnect
cancels pending work and clears session status; stale operation results cannot
update a new session. Log the numeric payload and retain raw notification logs.

The guide's LED manager may prioritize or alternate crash indications over the
BLE-set colour. Accepted values are not proof of visible hardware colour; the
guide also notes swapped red/green pins on some hardware revisions. Physical
command/reply, charging rejection and LED appearance still need verification.

The RGB implementation passed a Debug iOS simulator target build and
`git diff --check` on 14 October 2026. Physical LED verification remains pending.

## Retrieval, progress, and session lifetime

Retrieve is enabled only after initial reads finish on a live prepared connection,
with both channels subscribed and no competing operation. Known online mode
(configuration bit `02`) blocks this offline flow; the app does not change mode.
Offline mode is bit `01`. Unknown mode after a failed optional read is not guessed.

Arm reception before writing numeric `01` on the full discovered `6166` channel;
an empty replay may finish immediately. An ATT response only acknowledges writing.
Completion requires exact four-byte marker **`01 33 55 AA`**. Serialize all data
operations because retrieval and erase share the channel and marker.

Before `01`, synchronize the IMU clock using numeric `0A` on the discovered alert
channel. `HelmetIMUClock.swift` owns `TS:XXXXXXXX` parsing, request serialization,
a five-second response timeout, cancellation, and the phone/counter time mapping.
Pair the first valid reply with its phone receive time and retain that pair only
for this retrieval. A failed sync does not prevent raw crash download. No automatic
counter reset is performed; resetting before mapping older crashes loses their reference.

| Event packet bytes | Meaning |
| --- | --- |
| 0 | Frame number 1–64 |
| 1 | Sensor `01` for frames 1–60, `02` for frames 61–64 |
| 2 | Offline type: `43` fall, `53` crash after free-fall, `63` impact |
| 3–5 | Opaque 24-bit crash ID |
| 6–9 | Raw IMU timestamp, decoded as little-endian UInt32 |
| 10–129 | 120 sample bytes |

Require exactly 130 bytes. This layout follows the 9 October 2026 device capture:
64 complete 130-byte packets with the same four-byte value after the crash ID.
The guide still describes the older 126-byte BLE layout. Section 6.1 documents
25 microseconds per tick; the current user-requested trial uses 25.70 microseconds
per tick as described under CSV export. Capture-point
semantics and runtime clock accuracy remain unverified. Defined low-power types `73`/`83`/`93`
are accepted and labelled; the guide says they are unused. Live type `11`, unknown/short/malformed
values increment invalid/non-offline count and cannot become offline events.

Records are held only in memory, by session and record ordinal/ID/frame inventory.
A changed ID starts another record. Frame 1 after a full 64-frame record, or after
an incomplete record that never received frame 1, starts a new record rather than
assuming a merge. Identical duplicates do not advance unique progress; conflicting
frames and inconsistent packet types or IMU timestamps prevent a complete-event
label. IDs are not globally unique. A complete event has 64 distinct valid conflict-free frames.

Show valid/unique packets, current event frames, events started, complete/partial
events, duplicates/invalid counts, elapsed time, approximate percentage and ETA.
Initial ETA uses ~2-second startup + 64 packets/event at 120 ms + 200 ms between
events (~81 seconds for ten). Adapt packet spacing after five usable observations;
exclude event boundaries and implausible intervals. The original 6–7 seconds per
event request is an estimate; guide timings are the starting reference.

Suppress percentage/ETA for zero or clamped counts, events/frames exceeding the
scan estimate, or invalid notifications. Reaching estimated 100% means **waiting
for end marker**, not completion. An end marker with missing/conflicting/invalid
data means replay ended with issues, not all events were received. An empty replay
means no downloadable records, not an empty partition.

Use a 20-second first-response timeout and 15-second notification-stall timeout;
there is no whole-transfer cap. Keep the screen awake during retrieve/delete and
restore the previous idle-timer setting afterward. Disable Back/Disconnect and
competing actions during commands, transfers, and export preparation/sharing.

Retrieve once per connection to avoid replacing received data with an empty replay.
The firmware marks records transmitted during replay and skips them on later
requests, even when the phone misses notifications. No automatic retry/resume or
recovery guarantee. After a timeout with the connection still open, allow exporting
available partial samples; require reconnect before another BLE command. Reconnecting
clears that data, so export first if a copy is needed.

Clear all crash records, counters, timing, and operation state on Disconnect, Back,
new connection, Bluetooth/notification loss, or backgrounding. App termination also
loses volatile data. A share sheet alone is not app backgrounding; if a selected
activity takes the app into the background, the BLE session closes and only the
already-created CSV bytes may remain for that active sharing operation. Do not
promise background retrieval or recovery after relaunch.

## CSV export

Export CSV is available once retrieval is no longer busy and at least one event
has received valid frames. It also allows partial data after a timeout while the
connection remains open. Decode and create CSV **only when tapped**, on an actor
away from the UI actor. No automatic file generation during transfer.

CSV is UTF-8 with quoted/escaped fields and CRLF rows, one row per available sample:

- Session UUID, device name/MAC/firmware, app download and first-receipt dates.
- Event ordinal, opaque crash ID, type/classification, completeness, missing and
  conflicting frames, duplicate count, header consistency, end-marker/invalid counts.
- `event_imu_timestamp_raw`: the event's unsigned raw IMU timestamp from bytes 6–9,
  repeated on every sample row, without assuming time units or a calendar date.
- `event_estimated_crash_at`: calculated during retrieval as paired phone time
  minus `(current IMU seconds - event IMU seconds)`, with both raw values
  converted using the supplied Python overflow calculation described below. Export
  retains the calculated value; it never substitutes export time as the anchor.
- `event_estimated_crash_at_ist`: the same calculated crash time formatted in
  India Standard Time with milliseconds and an explicit `+05:30` offset. The
  original `event_estimated_crash_at` stays in UTC (`Z`); both are blank when
  crash time is unavailable.
- `event_time_status`: `estimated`, `clock_unavailable`, `units_unconfirmed`,
  `counter_not_comparable`, or `inconsistent_event_header`. Unavailable dates are blank.
- `retrieval_imu_timestamp_raw`, `retrieval_imu_clock_received_at` and
  `imu_seconds_per_tick`: the calculation's counter, paired phone time, and unit.
- Sample block, frame, index within that block, seconds from that block's start.
- Gyro XYZ in dps, IMU acceleration XYZ in g, high-g XYZ in g, possible unmeasured gyro.
- `raw_packet_hex`: the full original 130-byte packet (header and payload) as
  uppercase, space-separated hex, repeated for each sample decoded from that frame.
  This is the retained packet used for decoding; conflicting alternatives and
  invalid notifications are represented by quality flags/counts, not extra raw rows.

Frames 1–30 contain 300 pre-IMU samples at 104 Hz; 31–60 contain 300 post-IMU samples
at 52 Hz; 61–64 contain 80 high-g samples at ~1 kHz. Decode delivered little-endian
int16 gyro XYZ/acceleration XYZ using 0.07 dps/LSB and 0.000488 g/LSB. High-g words
are signed 12-bit: mask `0x0FFF`, subtract `0x1000` when >=`0x0800`, multiply by
0.195 g/LSB. Firmware already adjusts axes/calibration. Flag all-zero pre-gyro as
possibly unmeasured. Partial/conflicting data retains quality labels; do not invent
missing samples. Separate block clocks do not prove cross-buffer alignment.

BLE event packets include the raw IMU timestamp, but no calendar date/time.
Download/receipt dates remain explicitly labelled and separate from estimated
crash dates. Sample timing is relative to each separate block. For the trial
requested on 12 October 2026, conversion uses 25.70 microseconds per tick,
configured centrally as `HelmetIMUClock.secondsPerTick = 0.00002570`, instead
of the guide's documented 25 microseconds. Firmware confirmation remains pending.
As requested on 12 October 2026,
match the supplied Python script by decoding each raw value's low 24 bits as
the counter and high byte as the overflow count. Convert each separately as
`seconds = (overflow * 0xFF0000 + counter) * 0.00002570`, using
`IMUClockAnchor.ticksPerOverflow = 0xFF0000`. Subtract the event seconds from
the sync seconds, then subtract that duration from the phone receive time
paired with `TS:`. Raw packet and sync values remain unchanged in the CSV.
This treats the added event field as the same clock returned by `TS:`;
physical clock accuracy remains to be verified with the new firmware.
An event raw value or converted time larger than its anchor remains unavailable: it can mean a reset,
rollover, or an event after synchronization. Counter continuity through reboot
and multiple full rollovers cannot be established from these values alone.

Pass CSV bytes and suggested `.csv` filename to the native share sheet using
`NSItemProvider` and [UIActivityItemsConfiguration](https://developer.apple.com/documentation/uikit/uiactivityitemsconfiguration).
The app does not write an export file. iOS or the user's selected destination may
materialize/store a copy as part of sharing. Clear the app's CSV payload when the
sheet closes. Sharing completion means handoff to an activity, not verified durable
backup. Cancellation/failure permits another export while the session is alive.

## Manual deletion and disconnect

### Manual IMU clock reset

Show **Reset IMU clock** below Export CSV for use after exporting. This is an
explicit user action, including when no crash records were returned. It writes
numeric `09` to the discovered `1002` characteristic, then numeric `0A` to read
back the counter. All reset/request state and verification remain in
`HelmetIMUClock.swift`. Verify the counter is near zero using the same
overflow-to-seconds conversion as crash estimation, allowing
elapsed command time plus one second of app tolerance. A write ACK alone is not
reported as success. Show the read-back counter on successful verification.

Disable reset during connection/dashboard preparation, clock synchronization,
retrieval, erase, and CSV generation/sharing. Disable competing actions and
Back/Disconnect while resetting. Disconnect/backgrounding cancels pending clock
work and ignores stale results. Failed or missing read-back leaves reset
unverified and requires reconnect before another device command; existing RAM
records remain exportable while the connection remains open.

Reset does not erase helmet records or clear downloaded data. Previously
calculated dates and the retrieval clock anchor stored in each record remain
unchanged for later exports. No automatic reset or automatic erase is performed.

The manual reset implementation passed a Debug iOS simulator target build and
`git diff --check` on 9 October 2026. Physical reset/read-back verification remains pending.

### Manual data deletion

Delete from Helmet is a separate destructive action after retrieval's end marker
and all pending writes settle. Never delete automatically on packet count, write
acknowledgement, or export. Show a confirmation that numeric `02` on `6166` erases
**the entire offline partition**, including any new records since retrieval. There
is no documented per-event or transactional delete. Warn explicitly if received
records are partial/invalid; the user may still intentionally erase for this POC.
Export first if a copy is wanted; deletion is not gated on a claimed saved backup.

Arm deletion state before writing `02`. Only the exact completion marker confirms
the erase operation; the write ACK does not. A 60-second app-policy watchdog shows
an **unknown result** if no marker arrives; the guide does not give an erase duration.
Unexpected data, write errors, or disconnect before confirmation also mean unknown.
Require reconnect before another command. Do not auto-retry an erase.

After confirmed erase, disable Delete for that session and retain received records
in RAM for optional export until disconnect. Leave Stored Events at Scan labelled
as its old snapshot. A fresh advertisement can provide further device evidence;
do not invent a connected zero count. The erase also clears the red crash LED.

Disconnect and Back end the connection, cancel consumers/reads, invalidate late
operations, and clear crash data. There is no documented safe transfer-cancel
command. Give wake/double-tap/re-scan guidance after disconnect.

## Ten-step plan and current status

| Step | Status and deliverable | User focus |
| --- | --- | --- |
| 1. Foundation | Implemented: Bluetooth purpose string and `#00C8DC` tint | Target phone OS and first permission request |
| 2. Home | Implemented: fixed Quin logo, scrollable content, glass actions | Layout, larger text, contrast |
| 3. BLE session and permission | Implemented: app-owned transport, readiness/lifecycle, console-only logging | Denied permission, Bluetooth power, Settings return |
| 4. Decathlon discovery | Implemented: separate scanner, strict manufacturer filter, four-field rows | Advertising window, correct identity, malformed/stale rows |
| 5. Connection preparation | Implemented: full UUID discovery, property validation, both subscriptions | User reports connection works; confirm UUIDs/notification delivery |
| 6. Dashboard | Implemented: battery/temperature/activity, read-only thresholds, Device Information, Disconnect | Compare device readings and LightBlue values |
| 7. Retrieve and assemble | Implemented: `01`, RAM records, validation, decoder, exact completion marker | 130-byte delivery, 64 frames/event, partial/duplicate cases |
| 8. Progress and interruption | Implemented: adaptive ETA, elapsed time, timeout labels, session cleanup | Measured duration and partial export before ending session; no local recovery |
| 9. CSV share | Implemented under latest scope change: decode on tap, in-memory native sharing | CSV destination compatibility, units, sample counts, cancellation |
| 10. Manual erase | Implemented under latest scope change: confirmation, `02`, marker/unknown result, disconnect | Entire-partition behavior, completion timing, fresh scan count |

## Firmware limitations and validation

- iOS negotiates ATT MTU internally; there is no Android-style request-MTU API.
  The 9 October 2026 capture contains all 64 full 130-byte notifications and the
  end marker; app assembly with the updated decoder still needs runtime confirmation.
- RTC `1003` write encoding is absent: length, epoch, byte order, units, and clock
  semantics need clarification. RTC setup remains pending; do not guess a write.
- Idle sleep can close a connection after roughly 60 seconds without motion;
  transfer/erase should prevent sleep according to the guide.
- Mid-transfer disconnect behavior and retry guarantees are not established.
  The session-only requirement deliberately provides no persistent local copy.
- Open characteristics/no pairing are described in the guide; selected identity
  alone is not authenticated ownership.
- Battery/temperature logs `03`/`04`, crash-LED acknowledgement on alerts,
  live diagnostic `6266`, configuration editing, and reports are outside scope.

Validation on 9 October 2026: the 130-byte decoder passed a Debug iOS simulator
target build and `git diff --check`. Manual replay of the supplied real BLE capture
through the updated packet decoder, assembler and CSV exporter produced one
complete 64-frame event, zero rejected packets, raw timestamp 83,231, and 680 CSV
sample rows (300 pre-IMU, 300 post-IMU, 80 high-g). Every CSV row retained its full
130-byte packet and raw event timestamp. A subsequent physical-app capture
confirmed two complete events, zero partial/invalid packets, and the end marker;
their raw timestamps were 10,618 and 31,100. Physical CSV sharing remains unverified.

The retrieval-time clock integration requests a fresh counter before download
and retains calculated event dates for later CSV export. Its Debug iOS simulator
build and diff check passed. Manual replay of the two-event physical capture
retained both complete events and produced 1,360 CSV rows with 38 columns. That
older capture has no clock response, so estimated dates correctly remain blank
with `clock_unavailable`. Conversion was initially enabled using the guide's
documented 25-microsecond tick; the current 25.70-microsecond trial is described
above. Runtime confirmation of `TS:` responses, counter continuity
and clock accuracy remains pending.

Validation on 7 October 2026: the session-only implementation passed a Debug iOS
simulator target build against the pinned QuinKit source and `git diff --check`.
No unit tests, mocks, fixtures, or synthetic BLE data were added. Earlier actual
simulator navigation confirmed Home → Nearby Helmets in unsupported-Bluetooth
state. No populated session UI, physical replay, CSV sharing destination, erase,
measured ETA, or interruption behavior has been observed by the agent.

Next physical checks: retrieve known events, compare actual complete/partial counts
and timing, inspect a shared CSV's units/sample rows, cancel and repeat sharing in
the same connection, confirm session clearing after disconnect/background, and
verify explicitly requested erase completion followed by wake/double-tap/re-scan.
