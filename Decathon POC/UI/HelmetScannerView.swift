import SwiftUI

struct HelmetScannerView: View {
    let session: BluetoothSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text(session.isBluetoothReady ? "Find your helmet" : session.readiness.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if session.scanPhase == .scanning {
                        ProgressView().accessibilityLabel("Scanning for helmets")
                    }
                }

                Text(scanMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                accessAction

                ForEach(session.discoveredHelmets) { helmet in
                    HelmetScanResultRow(helmet: helmet)
                }

                if !session.discoveredHelmets.isEmpty {
                    Text("Battery and stored event count are reported in the helmet's advertisement. Scan again to refresh completed results.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            scanAction
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationTitle("Nearby helmets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            await session.enterScanner()
        }
        .onDisappear {
            session.leaveScanner()
        }
    }

    private var scanAction: some View {
        POCActionButton(
            title: scanButtonTitle,
            systemImage: session.scanPhase == .scanning ? "stop.fill" : "magnifyingglass",
            prominence: session.scanPhase == .scanning ? .secondary : .primary
        ) {
            if session.scanPhase == .scanning {
                session.stopScan()
            } else {
                Task { await session.startScan() }
            }
        }
        .disabled(!session.isBluetoothReady || session.isStartingScan)
        .opacity(session.isBluetoothReady ? 1 : 0.55)
    }

    @ViewBuilder
    private var accessAction: some View {
        switch session.readiness {
        case .needsPermission:
            POCActionButton(title: "Allow Bluetooth", systemImage: "antenna.radiowaves.left.and.right") {
                Task { await session.requestPermissionIfNeeded() }
            }
        case .permissionDenied:
            POCActionButton(title: "Open Settings", systemImage: "gearshape") {
                session.openSettings()
            }
        case .poweredOff:
            POCActionButton(title: "Refresh status", systemImage: "arrow.clockwise", prominence: .secondary) {
                session.refresh()
            }
        case .requestingPermission, .starting, .resetting, .unsupported, .ready:
            EmptyView()
        }
    }

    private var scanButtonTitle: String {
        switch session.scanPhase {
        case .idle: "Scan for helmets"
        case .scanning: "Stop scanning"
        case .finished, .stopped, .interrupted, .failed: "Scan again"
        }
    }

    private var scanMessage: String {
        guard session.isBluetoothReady else { return session.readiness.message }

        switch session.scanPhase {
        case .idle:
            return "Double-tap your helmet, then scan to find it nearby."
        case .scanning:
            return session.discoveredHelmets.isEmpty
                ? "Looking for Decathlon helmets. Double-tap your helmet to make it discoverable."
                : "Looking for Decathlon helmets. Results update as advertisements arrive."
        case .finished:
            return session.discoveredHelmets.isEmpty
                ? "No Decathlon helmets in the latest results. Wake your helmet, double-tap it, and scan again."
                : "Scan complete. These are the results from the last scan."
        case .stopped:
            return "Scanning stopped. Double-tap your helmet and scan again when you're ready."
        case .interrupted:
            return "Scanning was interrupted. Scan again to refresh nearby helmets."
        case .failed(let message):
            return "Could not scan for helmets. \(message)"
        }
    }
}
