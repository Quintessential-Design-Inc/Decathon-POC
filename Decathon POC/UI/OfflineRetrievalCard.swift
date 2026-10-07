import SwiftUI

struct OfflineRetrievalCard: View {
    let connection: HelmetConnection
    @State private var csvPayload: SessionCSVPayload?
    @State private var exportJobID: UUID?
    @State private var exportMessage: String?
    @State private var isConfirmingDelete = false
    private let exporter = SessionCSVExporter()
    private var retrieval: OfflineRetrieval { connection.retrieval }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Offline data · this session").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                Text(operationTitle).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if retrieval.isBusy || connection.csvExportID != nil { ProgressView().accessibilityLabel(operationTitle) }
            }
            if retrieval.sessionID != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in transferProgress(at: context.date) }
                Text("\(retrieval.receivedPacketCount) valid packets · \(retrieval.completeEventCount) complete events received")
                    .font(.subheadline.monospacedDigit())
                if retrieval.phase == .receiving {
                    Text("Current event: \(retrieval.currentFrameCount)/64 unique packets").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if retrieval.invalidPacketCount > 0 || retrieval.duplicatePacketCount > 0 || retrieval.partialEventCount > 0 {
                    Text("Partial events: \(retrieval.partialEventCount) · Duplicates: \(retrieval.duplicatePacketCount) · Invalid/non-offline packets: \(retrieval.invalidPacketCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(message).font(.footnote).foregroundStyle(.secondary)
            if let notice = connection.sessionDataNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            if connection.isReadingDashboard {
                Text("Waiting for initial device reads to finish.").font(.footnote).foregroundStyle(.secondary)
            }
            if let thresholds = connection.thresholds, thresholds.crashMode & 0x02 != 0 {
                Text("Online crash sending is enabled. Use offline-only mode for this flow.").font(.footnote).foregroundStyle(.secondary)
            }
            POCActionButton(title: "Retrieve offline data", systemImage: "arrow.down.doc") {
                Task { await connection.retrieveOfflineData() }
            }.disabled(!connection.canRetrieveOfflineData)

            POCActionButton(title: "Export CSV", systemImage: "square.and.arrow.up") {
                exportCSV()
            }.disabled(!connection.canExportCSV)
            if let exportMessage { Text(exportMessage).font(.footnote).foregroundStyle(.secondary) }

            Button(role: .destructive) { isConfirmingDelete = true } label: {
                Label("Delete from helmet", systemImage: "trash")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 28).padding(.vertical, 6).padding(.horizontal, 12)
            }
            .controlSize(.large)
            .buttonStyle(.glass)
            .disabled(!connection.canDeleteOfflineData)
            Text("Data stays in memory only. Export before disconnecting or leaving the app. Deleting the helmet's data is a separate action.")
                .font(.footnote).foregroundStyle(.secondary)

            if !retrieval.records.isEmpty {
                DisclosureGroup("Received event details") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(retrieval.records, id: \.ordinal) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Event \(event.ordinal) · \(event.classification)").font(.subheadline.weight(.semibold))
                                Text("ID \(event.crashID) · \(event.frames.count)/64 frames · \(event.isComplete ? "Complete" : "Partial / conflicting")")
                                    .font(.caption.monospaced())
                                if !event.missingFrames.isEmpty { Text("Missing: \(event.missingFrames.map(String.init).joined(separator: ", "))").font(.caption) }
                                if !event.conflictingFrames.isEmpty { Text("Conflicting: \(event.conflictingFrames.sorted().map(String.init).joined(separator: ", "))").font(.caption) }
                            }
                        }
                    }.padding(.top, 8)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .confirmationDialog("Delete all offline data from this helmet?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete all offline data", role: .destructive) {
                Task { await connection.deleteOfflineData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteConfirmation)
        }
        .sheet(item: $csvPayload, onDismiss: endExport) { payload in
            CSVShareSheet(payload: payload) { completed, error in
                exportMessage = error.map { "CSV sharing failed: \($0)" }
                    ?? (completed ? "CSV handed to the selected sharing activity." : "Sharing cancelled. You can export again during this session.")
                csvPayload = nil
                endExport()
            }
        }
    }

    private func exportCSV() {
        guard let (id, snapshot) = connection.beginCSVExport() else { return }
        exportJobID = id
        exportMessage = "Preparing CSV…"
        Task {
            do {
                let payload = try await exporter.makeCSV(snapshot)
                guard connection.retrieval.sessionID == snapshot.sessionID, connection.phase == .ready else {
                    exportMessage = "The connection ended while preparing CSV. Session data was cleared."
                    endExport()
                    return
                }
                exportMessage = nil
                csvPayload = payload
            } catch {
                exportMessage = "Could not prepare CSV: \(error.localizedDescription)"
                endExport()
            }
        }
    }
    private func endExport() {
        if let exportJobID { connection.finishCSVExport(exportJobID) }
        exportJobID = nil
    }

    private var operationTitle: String {
        if connection.csvExportID != nil { return "Exporting CSV" }
        switch retrieval.deletionPhase {
        case .waitingForCompletion: return "Deleting offline data"
        case .completed: return "Helmet confirmed deletion"
        case .failed: return "Erase result unknown"
        case .idle: return retrieval.waitingForEndMarker ? "Waiting for end marker" : retrieval.phase.title
        }
    }
    private var deleteConfirmation: String {
        let quality = retrieval.partialEventCount > 0 || retrieval.invalidPacketCount > 0
            ? "Some received data is partial or invalid. " : ""
        return quality + "This permanently erases the entire offline partition, including any events created after retrieval. Export CSV first if you need a copy. Data already received remains in memory until this connection ends."
    }
    private var message: String {
        switch retrieval.deletionPhase {
        case .waitingForCompletion: return "Waiting for the helmet's completion marker. Keep the app open and the helmet nearby."
        case .completed: return "The firmware confirmed the erase operation. You can still export received data before disconnecting."
        case .failed(let issue): return issue
        case .idle: break
        }
        switch retrieval.phase {
        case .idle: return "Connect, retrieve once, export CSV, then optionally delete the helmet's offline data."
        case .receiving: return "Keep the app open. Data is held in memory; Back and Disconnect are unavailable during transfer."
        case .finishing: return "Checking received event frames."
        case .completed: return retrieval.records.isEmpty
            ? "No downloadable records returned. Previously transmitted records may still exist on the helmet."
            : "Data is ready for this session. Export CSV before disconnecting."
        case .failed(let issue): return issue
        }
    }
    @ViewBuilder private func transferProgress(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if retrieval.phase == .receiving {
                if let fraction = retrieval.estimatedProgress {
                    ProgressView(value: fraction).accessibilityLabel("Approximate transfer progress")
                    Text(retrieval.waitingForEndMarker ? "Scan estimate reached; waiting for the helmet to finish." : "About \(Int(fraction * 100))% of the scan estimate")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("Receiving data; the scan count cannot provide a reliable percentage.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Elapsed: \(duration(retrieval.elapsed(at: now)))").font(.caption.monospacedDigit())
            if let remaining = retrieval.estimatedRemaining(at: now) {
                Text("Approximate remaining: \(duration(remaining))").font(.subheadline.weight(.medium).monospacedDigit())
                Text("Estimate uses packet timing and the scan count; previously transmitted records may be skipped.").font(.caption).foregroundStyle(.secondary)
            }
            if retrieval.phase == .receiving {
                Text("\(retrieval.uniquePacketCount) unique frames · \(retrieval.eventsStarted) events started · scan estimate \(retrieval.advertisedEventCount)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
    private func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(ceil(max(0, interval)))
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}
