import Foundation
import Observation
import QuinKitBLE
import QuinKitLogger
import UIKit

@MainActor
@Observable
final class OfflineRetrieval {
    private(set) var phase: OfflineRetrievalPhase = .idle
    private(set) var receivedPacketCount = 0
    private(set) var invalidPacketCount = 0
    private(set) var duplicatePacketCount = 0
    private(set) var storedEvents: [StoredCrashEvent] = []
    private(set) var currentFrameCount = 0
    private(set) var downloadDirectory: URL?
    private(set) var downloadID: UUID?
    private(set) var requiresReconnect = false
    private(set) var receivedEndMarker = false
    private(set) var isCommandPending = false

    @ObservationIgnored private var records: [CrashRecord] = []
    @ObservationIgnored private var store: OfflineDownloadStore?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastNotificationAt = Date()
    @ObservationIgnored private var previousIdleTimerDisabled: Bool?
    @ObservationIgnored private var isProcessingNotification = false

    deinit { watchdog?.cancel() }

    var isBusy: Bool { phase == .preparing || phase == .receiving || phase == .finishing || isCommandPending }
    var completeEventCount: Int { storedEvents.filter(\.complete).count }
    var partialEventCount: Int { storedEvents.filter { !$0.complete }.count }

    func resetForConnection() {
        guard !isBusy else { return }
        phase = .idle
        receivedPacketCount = 0
        invalidPacketCount = 0
        duplicatePacketCount = 0
        storedEvents = []
        records = []
        currentFrameCount = 0
        downloadDirectory = nil
        downloadID = nil
        requiresReconnect = false
        receivedEndMarker = false
    }

    func start(context: OfflineDownloadContext, peripheral: QKPeripheral, profile: DecathlonProfile) async {
        guard !isBusy, !requiresReconnect else { return }
        resetForConnection()
        operationID = UUID()
        let id = operationID
        downloadID = context.id
        phase = .preparing
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let writer = OfflineDownloadStore()
        store = writer
        do {
            downloadDirectory = try await writer.open(context: context)
            guard operationID == id, phase == .preparing else { return }
            guard peripheral.isConnected,
                  peripheral.characteristic(serviceUUID: profile.data.serviceUUID, uuid: profile.data.uuid)?.isNotifying == true,
                  peripheral.characteristic(serviceUUID: profile.alerts.serviceUUID, uuid: profile.alerts.uuid)?.isNotifying == true else {
                throw StoreError("Connection or notification channels are no longer ready.")
            }
            // Arm reception and storage BEFORE writing: an empty replay can end immediately.
            phase = .receiving
            lastNotificationAt = Date()
            startWatchdog(operation: id)
            QKLog.debug(tag: "Offline", "Sending offline retrieval command 01", context.id, profile.data.id)
            isCommandPending = true
            defer {
                isCommandPending = false
                if phase == .completed || phase.isFailure { restoreIdleTimer() }
            }
            try await peripheral.writeValue(Data([0x01]), for: profile.data, type: profile.dataWriteType, timeout: 10)
            // ATT acknowledgment is not replay completion; only the end marker closes it.
        } catch {
            guard operationID == id, isBusy, phase != .finishing else { return }
            await finish(endMarker: false, issue: "Could not start retrieval. \(error.localizedDescription)")
        }
    }

    func receive(_ data: Data, at date: Date) async {
        guard phase == .receiving, let store else { return }
        isProcessingNotification = true
        defer { isProcessingNotification = false }
        let id = operationID
        lastNotificationAt = date
        do {
            try await store.append(data, receivedAt: date)
            guard operationID == id, phase == .receiving else { return }
            if data == CrashPacket.endMarker {
                receivedEndMarker = true
                await finish(endMarker: true, issue: nil)
                return
            }
            let packet: CrashPacket
            do { packet = try CrashPacket(data: data) }
            catch {
                invalidPacketCount += 1
                QKLog.error(tag: "Offline", "Invalid or non-offline notification retained in raw journal", data.count, error)
                return
            }
            receivedPacketCount += 1
            // Records are serial on this firmware. An ordinal disambiguates reuse of
            // the opaque crash ID, including a new frame 1 after a completed record.
            if records.last == nil || records.last?.crashID != packet.crashID ||
                (packet.frame == 1 && records.last?.frames.count == 64) {
                if let previous = records.last {
                    let saved = try await store.save(previous)
                    guard operationID == id, phase == .receiving else { return }
                    remember(saved)
                }
                records.append(CrashRecord(packet: packet, ordinal: records.count + 1, receivedAt: date))
            }
            let index = records.count - 1
            let duplicatesBefore = records[index].duplicateCount
            records[index].add(packet, at: date)
            duplicatePacketCount += records[index].duplicateCount - duplicatesBefore
            currentFrameCount = records[index].frames.count
            if records[index].frames.count == 64 {
                let saved = try await store.save(records[index])
                guard operationID == id, phase == .receiving else { return }
                remember(saved)
            }
        } catch {
            guard operationID == id, phase == .receiving else { return }
            QKLog.error(tag: "Offline", "Could not preserve received data", error)
            await finish(endMarker: false, issue: "Local saving failed. \(error.localizedDescription)")
        }
    }

    /// Forced link/lifecycle loss: keep the journal and partial records; no auto retry.
    func interrupt(reason: String) {
        guard phase == .preparing || phase == .receiving else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finish(endMarker: false, issue: reason)
        }
        // Invalidate an awaiting append/command before it can mutate this operation.
        phase = .finishing
        watchdog?.cancel()
    }

    private func finish(endMarker: Bool, issue: String?) async {
        guard phase != .idle && phase != .completed && !phase.isFailure else { return }
        phase = .finishing
        watchdog?.cancel()
        watchdog = nil
        operationID = UUID()
        var finalIssue = issue
        guard let store else {
            phase = .failed(issue ?? "Download storage is unavailable.")
            requiresReconnect = true
            restoreIdleTimer()
            return
        }
        for record in records {
            do { remember(try await store.save(record)) }
            catch {
                finalIssue = [finalIssue, "Could not save event \(record.ordinal): \(error.localizedDescription)"].compactMap { $0 }.joined(separator: " ")
            }
        }
        let hasIssues = finalIssue != nil || invalidPacketCount > 0 || partialEventCount > 0
        do {
            let manifest = try await store.finish(
                status: endMarker ? (hasIssues ? "finished-with-issues" : "completed") : "interrupted",
                endMarker: endMarker, invalidCount: invalidPacketCount, issue: finalIssue
            )
            storedEvents = manifest.events
            receivedEndMarker = endMarker
            requiresReconnect = !endMarker || finalIssue != nil
            phase = finalIssue.map { .failed($0) } ?? (endMarker ? .completed : .failed("Retrieval was interrupted."))
            QKLog.debug(tag: "Offline", "Retrieval finalized", manifest.context.id, manifest.status,
                        completeEventCount, partialEventCount, invalidPacketCount)
        } catch {
            phase = .failed("Could not finalize saved download. \(error.localizedDescription)")
            requiresReconnect = true
            QKLog.error(tag: "Offline", "Download finalization failed", error)
        }
        self.store = nil
        if !isCommandPending { restoreIdleTimer() }
    }

    private func remember(_ event: StoredCrashEvent) {
        storedEvents.removeAll { $0.ordinal == event.ordinal }
        storedEvents.append(event)
        storedEvents.sort { $0.ordinal < $1.ordinal }
    }

    private func startWatchdog(operation: UUID) {
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.operationID == operation, self.phase == .receiving else { return }
                if self.isProcessingNotification { continue }
                // Per-response/stall timeout, never a short total-duration limit.
                let timeout: TimeInterval = self.receivedPacketCount == 0 && self.invalidPacketCount == 0 ? 20 : 15
                if Date().timeIntervalSince(self.lastNotificationAt) > timeout {
                    await self.finish(endMarker: false, issue: "The helmet stopped responding before the end marker. Partial data was retained. Reconnect before retrying; firmware may skip records already transmitted.")
                    return
                }
            }
        }
    }

    private func restoreIdleTimer() {
        if let previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
        previousIdleTimerDisabled = nil
    }
}

enum OfflineRetrievalPhase: Equatable {
    case idle, preparing, receiving, finishing, completed
    case failed(String)
    var isFailure: Bool { if case .failed = self { true } else { false } }
    var title: String {
        switch self {
        case .idle: "Ready to retrieve"
        case .preparing: "Preparing local storage"
        case .receiving: "Retrieving offline data"
        case .finishing: "Saving download"
        case .completed: "Replay finished"
        case .failed: "Retrieval interrupted"
        }
    }
}
