import SwiftUI

struct OfflineRetrievalCard: View {
    let connection: HelmetConnection
    private var retrieval: OfflineRetrieval { connection.retrieval }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Retrieve offline data").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                Text(retrieval.phase.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if retrieval.isBusy { ProgressView().accessibilityLabel(retrieval.phase.title) }
            }
            if retrieval.downloadID != nil {
                Text("\(retrieval.receivedPacketCount) valid packets · \(retrieval.completeEventCount) complete events saved")
                    .font(.subheadline.monospacedDigit())
                if retrieval.phase == .receiving {
                    Text("Current event: \(retrieval.currentFrameCount)/64 unique packets")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if retrieval.invalidPacketCount > 0 || retrieval.duplicatePacketCount > 0 || retrieval.partialEventCount > 0 {
                    Text("Partial events: \(retrieval.partialEventCount) · Duplicate packets: \(retrieval.duplicatePacketCount) · Invalid/non-offline packets: \(retrieval.invalidPacketCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(message).font(.footnote).foregroundStyle(.secondary)
            if connection.isReadingDashboard {
                Text("Waiting for initial device reads to finish.").font(.footnote).foregroundStyle(.secondary)
            }
            if let thresholds = connection.thresholds, thresholds.crashMode & 0x02 != 0 {
                Text("Online crash sending is enabled in the helmet's configuration. Use offline-only mode for this retrieval flow.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            POCActionButton(title: "Retrieve offline data", systemImage: "arrow.down.doc") {
                Task { await connection.retrieveOfflineData() }
            }
            .disabled(!connection.canRetrieveOfflineData)

            if !retrieval.storedEvents.isEmpty {
                DisclosureGroup("Saved event details") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(retrieval.storedEvents) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Event \(event.ordinal) · \(event.classification)").font(.subheadline.weight(.semibold))
                                Text("ID \(event.crashID) · \(event.frames.count)/64 frames · \(event.complete ? "Complete" : "Partial / conflicting")")
                                    .font(.caption.monospaced())
                                if !event.missingFrames.isEmpty {
                                    Text("Missing frames: \(event.missingFrames.map(String.init).joined(separator: ", "))").font(.caption)
                                }
                                if !event.conflictingFrames.isEmpty {
                                    Text("Conflicting frames: \(event.conflictingFrames.map(String.init).joined(separator: ", "))").font(.caption)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            if let id = retrieval.downloadID {
                Text("Download ID: \(id.uuidString)").font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private var message: String {
        switch retrieval.phase {
        case .idle:
            "Receive and save the helmet's offline crash data on this iPhone. Already transmitted records may be skipped."
        case .preparing:
            "Creating a local raw-data journal before requesting the helmet's records."
        case .receiving:
            "Keep the app open and the helmet nearby. Notifications are saved as they arrive. Disconnect and Back are unavailable until the transfer ends."
        case .finishing:
            "Saving event files and transfer metadata. Please keep the app open."
        case .completed:
            retrieval.completeEventCount == 0 && retrieval.invalidPacketCount == 0 && retrieval.partialEventCount == 0
                ? "No downloadable records were returned. The sensor may still contain previously transmitted records. Nothing was deleted."
                : "Download saved on this iPhone. Check partial or invalid data above. The sensor's records were not deleted."
        case .failed(let issue):
            "\(issue) Available raw data remains on this iPhone. Disconnect, double-tap, and reconnect before retrying."
        }
    }
}
