import Foundation
import Observation
import QuinKitBLE
import QuinKitLogger
import UIKit

/// One connection's volatile crash data and serialized retrieve/delete operations.
@MainActor
@Observable
final class OfflineRetrieval {
    private(set) var phase: OfflineRetrievalPhase = .idle
    private(set) var deletionPhase: OfflineDeletionPhase = .idle
    private(set) var receivedPacketCount = 0
    private(set) var invalidPacketCount = 0
    private(set) var duplicatePacketCount = 0
    private(set) var records: [CrashRecord] = []
    private(set) var currentFrameCount = 0
    private(set) var sessionID: UUID?
    private(set) var requiresReconnect = false
    private(set) var receivedEndMarker = false
    private(set) var isCommandPending = false
    private(set) var uniquePacketCount = 0
    private(set) var eventsStarted = 0
    private(set) var advertisedEventCount = 0
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var observedPacketInterval: TimeInterval = 0.12
    private(set) var timingObservationCount = 0

    @ObservationIgnored private var assembler = CrashRecordAssembler()
    @ObservationIgnored private var lastUniquePacketAt: Date?
    @ObservationIgnored private var requestStartedAt: Date?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastNotificationAt = Date()
    @ObservationIgnored private var previousIdleTimerDisabled: Bool?

    deinit { watchdog?.cancel() }

    var isBusy: Bool { phase == .receiving || phase == .finishing || deletionPhase == .waitingForCompletion || isCommandPending }
    var completeEventCount: Int { records.filter(\.isComplete).count }
    var partialEventCount: Int { records.filter { !$0.isComplete }.count }
    var hasUsableEstimate: Bool {
        advertisedEventCount > 0 && advertisedEventCount < 255 && eventsStarted <= advertisedEventCount &&
            uniquePacketCount <= advertisedEventCount * 64 && invalidPacketCount == 0
    }
    var estimatedProgress: Double? {
        guard phase == .receiving, hasUsableEstimate else { return nil }
        return Double(uniquePacketCount) / Double(advertisedEventCount * 64)
    }
    var waitingForEndMarker: Bool { phase == .receiving && hasUsableEstimate && uniquePacketCount == advertisedEventCount * 64 }

    func elapsed(at now: Date) -> TimeInterval {
        startedAt.map { max(0, (finishedAt ?? now).timeIntervalSince($0)) } ?? 0
    }
    func estimatedRemaining(at now: Date) -> TimeInterval? {
        guard phase == .receiving, hasUsableEstimate, !waitingForEndMarker else { return nil }
        let remainingFrames = max(0, advertisedEventCount * 64 - uniquePacketCount)
        let startup = uniquePacketCount == 0 ? max(0, 2 - now.timeIntervalSince(requestStartedAt ?? now)) : 0
        let gaps = max(0, advertisedEventCount - max(eventsStarted, 1))
        return startup + Double(remainingFrames) * (timingObservationCount >= 5 ? observedPacketInterval : 0.12) + Double(gaps) * 0.2
    }

    /// End of connection/backgrounding: release all packet data and invalidate late writes.
    func clearSession() {
        operationID = UUID()
        watchdog?.cancel()
        watchdog = nil
        restoreIdleTimer()
        phase = .idle
        deletionPhase = .idle
        receivedPacketCount = 0
        invalidPacketCount = 0
        duplicatePacketCount = 0
        records = []
        assembler = CrashRecordAssembler()
        currentFrameCount = 0
        sessionID = nil
        requiresReconnect = false
        receivedEndMarker = false
        isCommandPending = false
        uniquePacketCount = 0
        eventsStarted = 0
        advertisedEventCount = 0
        startedAt = nil
        finishedAt = nil
        observedPacketInterval = 0.12
        timingObservationCount = 0
        lastUniquePacketAt = nil
        requestStartedAt = nil
    }

    func start(advertisedCount: Int, peripheral: QKPeripheral, profile: DecathlonProfile) async {
        guard phase == .idle, !isBusy, !requiresReconnect else { return }
        sessionID = UUID()
        operationID = UUID()
        let operation = operationID
        advertisedEventCount = advertisedCount
        startedAt = Date()
        keepScreenAwake()
        do {
            try validateChannels(peripheral, profile)
            // Arm reception before writing: an empty replay can end immediately.
            phase = .receiving
            lastNotificationAt = Date()
            requestStartedAt = lastNotificationAt
            startWatchdog(operation: operation, deleting: false)
            isCommandPending = true
            defer {
                if operationID == operation {
                    isCommandPending = false
                    if phase != .receiving { restoreIdleTimer() }
                }
            }
            QKLog.debug(tag: "Offline", "Requesting session-only offline data", profile.data.id)
            try await peripheral.writeValue(Data([0x01]), for: profile.data, type: profile.dataWriteType, timeout: 10)
        } catch {
            guard operationID == operation, !receivedEndMarker else { return }
            finishRetrieval(endMarker: false, issue: "Could not start retrieval. \(error.localizedDescription)")
        }
    }

    func receive(_ data: Data, at date: Date) {
        if deletionPhase == .waitingForCompletion {
            if data == CrashPacket.endMarker {
                deletionPhase = .completed
                watchdog?.cancel()
                if !isCommandPending { restoreIdleTimer() }
                QKLog.debug(tag: "Offline", "Helmet confirmed offline partition erase")
            } else {
                failDeletion("Unexpected data arrived while waiting for erase completion. The erase result is unknown.")
            }
            return
        }
        guard phase == .receiving else { return }
        lastNotificationAt = date
        if data == CrashPacket.endMarker {
            finishRetrieval(endMarker: true, issue: nil)
            return
        }
        guard let packet = try? CrashPacket(data: data) else {
            invalidPacketCount += 1
            QKLog.error(tag: "Offline", "Invalid or non-offline notification", data.count)
            return
        }
        receivedPacketCount += 1
        let previousUniqueCount = uniquePacketCount
        let previousEventCount = eventsStarted
        assembler.add(packet, at: date)
        records = assembler.records
        uniquePacketCount = assembler.uniqueFrameCount
        eventsStarted = records.count
        duplicatePacketCount = assembler.duplicateCount
        currentFrameCount = records.last?.frames.count ?? 0
        if uniquePacketCount > previousUniqueCount {
            if eventsStarted == previousEventCount, let lastUniquePacketAt {
                let interval = date.timeIntervalSince(lastUniquePacketAt)
                if (0.02...2).contains(interval) {
                    observedPacketInterval = 0.85 * observedPacketInterval + 0.15 * interval
                    timingObservationCount += 1
                }
            }
            lastUniquePacketAt = date
        }
    }

    func deleteOfflineData(peripheral: QKPeripheral, profile: DecathlonProfile) async {
        guard phase == .completed, receivedEndMarker, !isBusy, !requiresReconnect, deletionPhase == .idle else { return }
        operationID = UUID()
        let operation = operationID
        do {
            try validateChannels(peripheral, profile)
            keepScreenAwake()
            deletionPhase = .waitingForCompletion
            lastNotificationAt = Date()
            startWatchdog(operation: operation, deleting: true)
            isCommandPending = true
            defer {
                if operationID == operation {
                    isCommandPending = false
                    if deletionPhase != .waitingForCompletion { restoreIdleTimer() }
                }
            }
            QKLog.debug(tag: "Offline", "User confirmed offline partition erase; writing 02", profile.data.id)
            try await peripheral.writeValue(Data([0x02]), for: profile.data, type: profile.dataWriteType, timeout: 10)
        } catch {
            guard operationID == operation, deletionPhase != .completed else { return }
            failDeletion("Erase command failed or was not confirmed. Result is unknown. \(error.localizedDescription)")
        }
    }

    private func validateChannels(_ peripheral: QKPeripheral, _ profile: DecathlonProfile) throws {
        guard peripheral.isConnected,
              peripheral.characteristic(serviceUUID: profile.data.serviceUUID, uuid: profile.data.uuid)?.isNotifying == true,
              peripheral.characteristic(serviceUUID: profile.alerts.serviceUUID, uuid: profile.alerts.uuid)?.isNotifying == true else {
            throw ProfileError("Connection or notification channels are not ready.")
        }
    }

    private func finishRetrieval(endMarker: Bool, issue: String?) {
        phase = .finishing
        watchdog?.cancel()
        receivedEndMarker = endMarker
        requiresReconnect = !endMarker
        finishedAt = Date()
        phase = issue.map { .failed($0) } ?? .completed
        if !isCommandPending { restoreIdleTimer() }
        QKLog.debug(tag: "Offline", "Session retrieval ended", completeEventCount, partialEventCount, invalidPacketCount, endMarker)
    }

    private func failDeletion(_ message: String) {
        deletionPhase = .failed(message)
        requiresReconnect = true
        watchdog?.cancel()
        if !isCommandPending { restoreIdleTimer() }
        QKLog.error(tag: "Offline", "Erase result unknown", message)
    }

    private func startWatchdog(operation: UUID, deleting: Bool) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.operationID == operation else { return }
                if deleting {
                    guard self.deletionPhase == .waitingForCompletion else { return }
                    // App policy, not a documented firmware erase duration.
                    if Date().timeIntervalSince(self.lastNotificationAt) > 60 {
                        self.failDeletion("No erase completion marker arrived within 60 seconds. Result is unknown; reconnect before another command.")
                        return
                    }
                } else {
                    guard self.phase == .receiving else { return }
                    let initial = self.receivedPacketCount == 0 && self.invalidPacketCount == 0
                    if Date().timeIntervalSince(self.lastNotificationAt) > (initial ? 20 : 15) {
                        self.finishRetrieval(endMarker: false, issue: initial ? "No initial response within 20 seconds. Export any available data before disconnecting; retry may skip already transmitted records." : "No new data for 15 seconds before the end marker. Export the partial data before disconnecting; retry may skip already transmitted records.")
                        return
                    }
                }
            }
        }
    }

    private func keepScreenAwake() {
        if previousIdleTimerDisabled == nil { previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled }
        UIApplication.shared.isIdleTimerDisabled = true
    }
    private func restoreIdleTimer() {
        if let previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
        previousIdleTimerDisabled = nil
    }
}

enum OfflineRetrievalPhase: Equatable {
    case idle, receiving, finishing, completed
    case failed(String)
    var title: String {
        switch self {
        case .idle: "Ready to retrieve"
        case .receiving: "Retrieving offline data"
        case .finishing: "Checking received frames"
        case .completed: "Replay finished"
        case .failed: "Retrieval interrupted"
        }
    }
}

enum OfflineDeletionPhase: Equatable {
    case idle, waitingForCompletion, completed
    case failed(String)
}
