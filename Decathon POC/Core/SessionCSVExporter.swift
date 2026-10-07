import Foundation

nonisolated struct SessionCSVSnapshot: Sendable {
    let sessionID: UUID
    let deviceName: String
    let macAddress: String
    let firmwareVersion: String
    let downloadStartedAt: Date
    let receivedEndMarker: Bool
    let invalidPacketCount: Int
    let records: [CrashRecord]
}

nonisolated struct SessionCSVPayload: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let filename: String
    let data: Data
}

/// Decode and create CSV on demand, entirely in memory and away from the UI actor.
actor SessionCSVExporter {
    func makeCSV(_ snapshot: SessionCSVSnapshot) throws -> SessionCSVPayload {
        let header = [
            "session_id", "device_name", "mac_address", "firmware_version", "download_started_at",
            "event_first_received_at", "event_ordinal", "crash_id", "packet_type_hex", "classification",
            "event_complete", "missing_frames", "conflicting_frames", "duplicate_packets", "inconsistent_header",
            "transfer_end_marker", "transfer_invalid_packets", "sample_block", "frame", "sample_index_in_block",
            "seconds_from_block_start", "gx_dps", "gy_dps", "gz_dps", "ax_g", "ay_g", "az_g", "ix_g", "iy_g", "iz_g", "gyro_may_be_unmeasured",
            "raw_packet_hex"
        ]
        var csv = Data((header.joined(separator: ",") + "\r\n").utf8)
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for record in snapshot.records {
            try Task.checkCancellation()
            let prefix = [
                snapshot.sessionID.uuidString, snapshot.deviceName, snapshot.macAddress, snapshot.firmwareVersion,
                dates.string(from: snapshot.downloadStartedAt), dates.string(from: record.firstReceivedAt),
                String(record.ordinal), record.crashID, String(format: "%02X", record.packetType), record.classification,
                String(record.isComplete), record.missingFrames.map(String.init).joined(separator: ";"),
                record.conflictingFrames.sorted().map(String.init).joined(separator: ";"), String(record.duplicateCount),
                String(record.inconsistentHeader), String(snapshot.receivedEndMarker), String(snapshot.invalidPacketCount)
            ]
            let decoded = record.decoded()
            // Samples from one frame share its complete original BLE packet.
            let rawPacketHex = record.frames.mapValues { packet in
                packet.map { String(format: "%02X", $0) }.joined(separator: " ")
            }
            for sample in decoded.imu {
                append(prefix + [sample.block, String(sample.frame), String(sample.indexWithinBlock),
                                 number(sample.secondsFromBlockStart), number(sample.gxDPS), number(sample.gyDPS), number(sample.gzDPS),
                                 number(sample.axG), number(sample.ayG), number(sample.azG), "", "", "", String(sample.gyroMayBeUnmeasured),
                                 rawPacketHex[sample.frame] ?? ""], to: &csv)
            }
            for sample in decoded.highG {
                append(prefix + ["high_g", String(sample.frame), String(sample.indexWithinBlock), number(sample.secondsFromBlockStart),
                                 "", "", "", "", "", "", number(sample.ixG), number(sample.iyG), number(sample.izG), "",
                                 rawPacketHex[sample.frame] ?? ""], to: &csv)
            }
        }
        let name = "QUIN-PRO-\(snapshot.sessionID.uuidString).csv"
        return SessionCSVPayload(id: UUID(), sessionID: snapshot.sessionID, filename: name, data: csv)
    }

    private func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private func append(_ fields: [String], to csv: inout Data) {
        let row = fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        csv.append(contentsOf: (row + "\r\n").utf8)
    }
}
