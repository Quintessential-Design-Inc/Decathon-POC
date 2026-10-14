import Foundation
import Observation

nonisolated enum IMUClockTimeStatus: String, Codable, Sendable {
    case estimated
    case clockUnavailable = "clock_unavailable"
    case unitsUnconfirmed = "units_unconfirmed"
    case counterNotComparable = "counter_not_comparable"
    case inconsistentHeader = "inconsistent_event_header"
}

nonisolated struct IMUClockTimeEstimate: Sendable {
    let date: Date?
    let status: IMUClockTimeStatus
}

/// A current counter and phone time captured together during retrieval.
nonisolated struct IMUClockAnchor: Sendable {
    let counterRaw: UInt32
    let receivedAt: Date
    let requestDuration: TimeInterval
    let secondsPerTick: TimeInterval?

    // Match the supplied Python calculation: the high byte counts 0xFF0000-tick intervals.
    static let ticksPerOverflow: UInt64 = 0xFF0000

    static func elapsedSeconds(rawTimestamp: UInt32, secondsPerTick: TimeInterval) -> TimeInterval {
        let counter = UInt64(rawTimestamp & 0x00FFFFFF)
        let overflow = UInt64(rawTimestamp >> 24)
        return Double(overflow * ticksPerOverflow + counter) * secondsPerTick
    }

    func estimateCrashTime(rawTimestamp: UInt32) -> IMUClockTimeEstimate {
        guard let secondsPerTick, secondsPerTick.isFinite, secondsPerTick > 0 else {
            return IMUClockTimeEstimate(date: nil, status: .unitsUnconfirmed)
        }
        let syncSeconds = Self.elapsedSeconds(rawTimestamp: counterRaw, secondsPerTick: secondsPerTick)
        let recordSeconds = Self.elapsedSeconds(rawTimestamp: rawTimestamp, secondsPerTick: secondsPerTick)
        // A larger event value can mean a reset, rollover or an event after the anchor.
        // Do not guess which occurred without firmware continuity information.
        guard rawTimestamp <= counterRaw, recordSeconds <= syncSeconds else {
            return IMUClockTimeEstimate(date: nil, status: .counterNotComparable)
        }
        let elapsed = syncSeconds - recordSeconds
        return IMUClockTimeEstimate(date: receivedAt.addingTimeInterval(-elapsed), status: .estimated)
    }
}

/// Owns IMU synchronization and time mapping; BLE transport stays in the connection layer.
@MainActor
@Observable
final class HelmetIMUClock {
    // Trial requested on 12 October 2026: 25.70 microseconds per tick; firmware confirmation pending.
    static let secondsPerTick: TimeInterval = 0.00002570
    private(set) var isSynchronizing = false
    private(set) var isResetting = false
    private(set) var resetMessage: String?
    private(set) var resetRequiresReconnect = false
    private(set) var issue: String?

    @ObservationIgnored private var resetID: UUID?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var continuation: CheckedContinuation<IMUClockAnchor, Error>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var requestStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var reply: IMUClockAnchor?
    @ObservationIgnored private var writeCompleted = false

    var isBusy: Bool { isSynchronizing || isResetting }

    func synchronize(write: @escaping @MainActor () async throws -> Void) async throws -> IMUClockAnchor {
        guard !isResetting, !resetRequiresReconnect else {
            throw ProfileError("The IMU clock is resetting or requires reconnect.")
        }
        return try await readCounter(write: write)
    }

    /// Reset only on an explicit user action, then read back the counter to verify it.
    func reset(writeReset: @escaping @MainActor () async throws -> Void,
               readCurrent: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy, !resetRequiresReconnect else { return }
        let id = UUID()
        resetID = id
        isResetting = true
        resetMessage = nil
        issue = nil
        let startedAt = ContinuousClock.now
        defer {
            if resetID == id {
                resetID = nil
                isResetting = false
            }
        }
        do {
            try Task.checkCancellation()
            try await writeReset()
            guard resetID == id else { return }
            try Task.checkCancellation()
            let anchor = try await readCounter(write: readCurrent)
            guard resetID == id else { return }
            try Task.checkCancellation()
            let duration = startedAt.duration(to: ContinuousClock.now).components
            let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            // App verification tolerance: allow elapsed command time plus one second.
            // A read/write ACK alone does not prove the device counter was reset.
            let counterSeconds = IMUClockAnchor.elapsedSeconds(rawTimestamp: anchor.counterRaw,
                                                               secondsPerTick: Self.secondsPerTick)
            guard counterSeconds <= elapsed + 1 else {
                throw ProfileError("Read-back counter \(anchor.counterRaw) is not near zero.")
            }
            resetMessage = "IMU clock reset verified. Read-back counter: \(anchor.counterRaw)."
        } catch {
            guard resetID == id else { return }
            resetRequiresReconnect = true
            resetMessage = "IMU clock reset could not be verified. \(error.localizedDescription) Reconnect before another device command."
        }
    }

    private func readCounter(write: @escaping @MainActor () async throws -> Void) async throws -> IMUClockAnchor {
        guard !isSynchronizing else { throw ProfileError("An IMU clock request is already running.") }
        try Task.checkCancellation()
        let id = UUID()
        issue = nil
        isSynchronizing = true
        requestID = id
        reply = nil
        writeCompleted = false

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                // Arm response handling before the write: the notification may arrive before its ACK.
                continuation = pending
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(id: id, result: .failure(ProfileError("No IMU clock response within 5 seconds.")))
                }
                writeTask = Task { @MainActor [weak self] in
                    guard let self, self.requestID == id else { return }
                    self.requestStartedAt = ContinuousClock.now
                    do {
                        try Task.checkCancellation()
                        try await write()
                        guard self.requestID == id else { return }
                        self.writeCompleted = true
                        self.finishIfReady(id: id)
                    } catch {
                        self.finish(id: id, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, result: .failure(CancellationError()))
            }
        }
    }

    /// Consume TS: replies without interfering with battery/activity notifications.
    @discardableResult
    func receive(_ data: Data, at date: Date) -> Bool {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("TS:") else { return false }
        guard let id = requestID, let requestStartedAt else { return true }
        let digits = Array(text.dropFirst(3).utf8)
        guard digits.count == 8,
              digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let raw = UInt32(text.dropFirst(3), radix: 16) else {
            finish(id: id, result: .failure(ProfileError("Malformed IMU clock response.")))
            return true
        }
        // Retain the first reply paired with its receive time; duplicate replies must not move the anchor.
        if reply == nil {
            let duration = requestStartedAt.duration(to: ContinuousClock.now).components
            reply = IMUClockAnchor(counterRaw: raw, receivedAt: date,
                requestDuration: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                secondsPerTick: Self.secondsPerTick)
        }
        finishIfReady(id: id)
        return true
    }

    func clearSession() {
        resetID = nil
        isResetting = false
        if let id = requestID { finish(id: id, result: .failure(CancellationError())) }
        resetMessage = nil
        resetRequiresReconnect = false
        issue = nil
    }

    private func finishIfReady(id: UUID) {
        guard writeCompleted, let reply else { return }
        finish(id: id, result: .success(reply))
    }

    private func finish(id: UUID, result: Result<IMUClockAnchor, Error>) {
        guard requestID == id else { return }
        let pending = continuation
        continuation = nil
        requestID = nil
        requestStartedAt = nil
        reply = nil
        writeCompleted = false
        isSynchronizing = false
        writeTask?.cancel()
        writeTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .failure(let error) = result, !(error is CancellationError) { issue = error.localizedDescription }
        pending?.resume(with: result)
    }
}
