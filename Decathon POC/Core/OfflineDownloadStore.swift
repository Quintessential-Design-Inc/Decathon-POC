import CryptoKit
import Foundation

nonisolated struct OfflineDownloadContext: Codable, Sendable {
    let id: UUID
    let peripheralID: UUID
    let deviceName: String
    let macAddress: String
    let advertisedEventCount: Int
    let startedAt: Date
    let deviceInformation: [String: String]
}

nonisolated struct StoredCrashEvent: Codable, Identifiable, Sendable {
    var id: Int { ordinal }
    let ordinal: Int
    let crashID: String
    let packetType: UInt8
    let classification: String
    let firstReceivedAt: Date
    let lastReceivedAt: Date
    let frames: [Int]
    let missingFrames: [Int]
    let conflictingFrames: [Int]
    let duplicateCount: Int
    let inconsistentHeader: Bool
    let complete: Bool
    let rawSHA256: String
    let decodedSHA256: String
    let rawFile: String
    let decodedFile: String
}

nonisolated struct OfflineDownloadManifest: Codable, Sendable {
    let schemaVersion: Int
    let context: OfflineDownloadContext
    var status: String
    var finishedAt: Date?
    var receivedEndMarker: Bool
    var journalNotificationCount: Int
    var invalidPacketCount: Int
    var issue: String?
    var events: [StoredCrashEvent]
    let timingNote: String
}

nonisolated private struct JournalNotification: Codable {
    let sequence: Int
    let receivedAt: Date
    let bytes: Data
}

/// Disk operations are serialized away from the BLE/UI actor. No cache-only storage.
actor OfflineDownloadStore {
    private var directory: URL?
    private var journal: FileHandle?
    private var manifest: OfflineDownloadManifest?
    private let encoder: JSONEncoder

    init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
    }

    func open(context: OfflineDownloadContext) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("OfflineDownloads", isDirectory: true)
            .appendingPathComponent(context.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
        manifest = OfflineDownloadManifest(
            schemaVersion: 1, context: context, status: "receiving", finishedAt: nil,
            receivedEndMarker: false, journalNotificationCount: 0, invalidPacketCount: 0, issue: nil, events: [],
            timingNote: "Dates are app receipt/download times. Original crash time is absent from BLE packets. Sample times start at each separate pre/post/high-g buffer; high-g rate is approximate. Zero pre-event gyro may be unmeasured."
        )
        try persistManifest()
        let url = folder.appendingPathComponent("notifications.jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw StoreError("Could not create the raw notification journal.")
        }
        journal = try FileHandle(forWritingTo: url)
        return folder
    }

    func append(_ data: Data, receivedAt: Date) throws {
        guard let journal, let manifest else { throw StoreError("Raw notification journal is not open.") }
        let entry = JournalNotification(sequence: manifest.journalNotificationCount + 1, receivedAt: receivedAt, bytes: data)
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try journal.write(contentsOf: line)
        // Persist each received value before reporting it as received/saved progress.
        try journal.synchronize()
        self.manifest?.journalNotificationCount += 1
    }

    func save(_ record: CrashRecord) throws -> StoredCrashEvent {
        guard let directory, journal != nil else { throw StoreError("Download store is not open.") }
        let prefix = String(format: "event-%03d-%@", record.ordinal, record.crashID)
        let rawFile = prefix + ".bin"
        let decodedFile = prefix + ".json"
        var raw = Data()
        for frame in record.frames.keys.sorted() {
            if let packet = record.frames[frame] { raw.append(packet) }
        }
        let decoded = record.decoded()
        let decodedData = try encoder.encode(decoded)
        let rawURL = directory.appendingPathComponent(rawFile)
        let decodedURL = directory.appendingPathComponent(decodedFile)
        try durableWrite(raw, to: rawURL)
        try durableWrite(decodedData, to: decodedURL)
        let savedRaw = try Data(contentsOf: rawURL)
        let savedDecodedData = try Data(contentsOf: decodedURL)
        let savedDecoded = try JSONDecoder().decode(DecodedCrashRecord.self, from: savedDecodedData)
        guard savedRaw == raw, savedDecodedData == decodedData, savedDecoded.crashID == record.crashID,
              savedDecoded.ordinal == record.ordinal,
              savedDecoded.imu.count == decoded.imu.count, savedDecoded.highG.count == decoded.highG.count else {
            throw StoreError("Saved event could not be verified.")
        }
        let saved = StoredCrashEvent(
            ordinal: record.ordinal, crashID: record.crashID, packetType: record.packetType,
            classification: record.classification, firstReceivedAt: record.firstReceivedAt, lastReceivedAt: record.lastReceivedAt,
            frames: record.frames.keys.sorted(), missingFrames: record.missingFrames,
            conflictingFrames: record.conflictingFrames.sorted(), duplicateCount: record.duplicateCount,
            inconsistentHeader: record.inconsistentHeader, complete: record.isComplete,
            rawSHA256: SHA256.hash(data: savedRaw).map { String(format: "%02x", $0) }.joined(),
            decodedSHA256: SHA256.hash(data: savedDecodedData).map { String(format: "%02x", $0) }.joined(),
            rawFile: rawFile, decodedFile: decodedFile
        )
        manifest?.events.removeAll { $0.ordinal == record.ordinal }
        manifest?.events.append(saved)
        manifest?.events.sort { $0.ordinal < $1.ordinal }
        try persistManifest()
        return saved
    }

    func finish(status: String, endMarker: Bool, invalidCount: Int, issue: String?) throws -> OfflineDownloadManifest {
        guard var updated = manifest else { throw StoreError("Download metadata is unavailable.") }
        try journal?.synchronize()
        try journal?.close()
        journal = nil
        updated.status = status
        updated.finishedAt = Date()
        updated.receivedEndMarker = endMarker
        updated.invalidPacketCount = invalidCount
        updated.issue = issue
        manifest = updated
        try persistManifest()
        return updated
    }

    private func persistManifest() throws {
        guard let directory, let manifest else { throw StoreError("Missing download metadata.") }
        try durableWrite(try encoder.encode(manifest), to: directory.appendingPathComponent("manifest.json"))
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

nonisolated struct StoreError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
