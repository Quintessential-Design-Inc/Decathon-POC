import CoreBluetooth
import SwiftUI
import QuinKitBLE

/// Connected dashboard; readings remain visible as history when the link closes.
struct HelmetConnectionView: View {
    let connection: HelmetConnection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identity

                if readingsAreHistorical {
                    Label("Readings below are from the last connection.", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                batteryCard
                eventsCard
                thresholdsCard
                activityCard
                deviceInformationCard
                diagnostics
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if connection.phase.isPreparing || connection.phase == .ready {
                POCActionButton(
                    title: connection.phase.isPreparing ? "Cancel connection" : "Disconnect",
                    systemImage: "xmark",
                    prominence: .secondary
                ) { connection.disconnect() }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationTitle("Your helmet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onDisappear { connection.disconnect() }
    }

    private var identity: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(connection.helmet?.name ?? "QUIN PRO")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let helmet = connection.helmet {
                        Text("MAC: \(helmet.advertisement.macAddress)")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                if connection.phase.isPreparing {
                    ProgressView().accessibilityLabel(connection.phase.title)
                } else if connection.phase == .ready {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Connected")
                }
            }
            Text(connection.phase.title).font(.headline)
            Text(connection.phase.message).font(.subheadline).foregroundStyle(.secondary)
            if connection.phase == .ready {
                Text("The helmet can sleep and disconnect after about a minute without motion.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var batteryCard: some View {
        card("Battery") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(batteryText).font(.largeTitle.bold()).monospacedDigit()
                if let battery = connection.battery {
                    Text(battery.category.title).font(.headline).foregroundStyle(.secondary)
                }
            }
            if let battery = connection.battery {
                receivedTime(battery.receivedAt, title: "Battery last received")
                if battery.fromRead {
                    Text("Read from the helmet's last battery status; its original measurement time is unavailable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if connection.helmet?.advertisement.batteryPercentage != nil {
                Text(connection.phase.isPreparing || connection.phase == .ready
                     ? "From scan advertisement. Waiting for connected battery status."
                     : "Last scan advertisement; no connected battery status was received.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            valueRow("Sensor temperature", value: temperatureText)
            if let temperature = connection.temperature {
                receivedTime(temperature.receivedAt, title: "Temperature last received")
            }
            if let issue = connection.batteryReadIssue {
                Text(issue).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var eventsCard: some View {
        card("Offline events") {
            valueRow("Stored events at scan", value: connection.helmet.map { String($0.advertisement.storedEventCount) } ?? "Unavailable")
            Text("This count was advertised before connection. It can include previously downloaded records that have not been erased.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var thresholdsCard: some View {
        card("Crash thresholds") {
            valueRow("Major threshold", value: connection.thresholds.map { "\($0.majorG) g" }
                     ?? (connection.thresholdReadIssue == nil ? waitingText : "Unavailable"))
            valueRow("Minor threshold", value: connection.thresholds.map { "\($0.minorG) g" }
                     ?? (connection.thresholdReadIssue == nil ? waitingText : "Unavailable"))
            if let thresholds = connection.thresholds {
                receivedTime(thresholds.receivedAt, title: "Configuration read")
            }
            Text("Read-only settings from the helmet's configuration.")
                .font(.footnote).foregroundStyle(.secondary)
            if let issue = connection.thresholdReadIssue {
                Text(issue).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var activityCard: some View {
        card("Activity") {
            valueRow("Helmet state", value: connection.activity?.title
                     ?? (connection.phase.isPreparing || connection.phase == .ready ? "Waiting for update" : "Unavailable"))
            if let receivedAt = connection.activityReceivedAt {
                receivedTime(receivedAt, title: "Last received")
            } else {
                Text("Activity appears when the helmet reports an active or inactive state change.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var deviceInformationCard: some View {
        card("Device information") {
            ForEach(HelmetDeviceInfoField.allCases) { field in
                valueRow(field.rawValue, value: connection.deviceInformation[field]
                         ?? (connection.deviceInformationIssues[field] == nil ? waitingText : "Unavailable"))
            }
        }
    }

    private var diagnostics: some View {
        card {
            DisclosureGroup("Connection diagnostics") {
                VStack(alignment: .leading, spacing: 16) {
                    if let profile = connection.profile {
                        channel("Offline data", characteristic: profile.data)
                        channel("Alerts", characteristic: profile.alerts)
                    }
                    Text("Notifications received — data: \(connection.dataNotificationCount), alerts: \(connection.alertNotificationCount)")
                        .font(.caption.monospacedDigit())
                    if let alert = connection.lastAlert {
                        Text("Latest alert: \(alert)").font(.caption).textSelection(.enabled)
                    }
                    Text("RTC setup is pending until its write encoding is provided. Retrieval, export, and deletion arrive in later steps.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(HelmetDeviceInfoField.allCases) { field in
                        if let issue = connection.deviceInformationIssues[field] {
                            Text("\(field.rawValue): \(issue)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(connection.services) { service in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Service: \(service.uuid.uuidString)").font(.caption.weight(.semibold).monospaced())
                            ForEach(service.characteristics) { characteristic in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(characteristic.uuid.uuidString).font(.caption.monospaced())
                                    Text(characteristic.propertySummary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private var batteryText: String {
        if let battery = connection.battery { return "\(battery.percentage)%" }
        if let percentage = connection.helmet?.advertisement.batteryPercentage { return "\(percentage)%" }
        return waitingText
    }

    private var temperatureText: String {
        connection.temperature.map { "\($0.celsius.formatted(.number.precision(.fractionLength(1)))) °C" } ?? waitingText
    }

    private var waitingText: String {
        connection.phase.isPreparing || connection.isReadingDashboard ? "Waiting…" : "Unavailable"
    }

    private var readingsAreHistorical: Bool {
        !connection.phase.isPreparing && connection.phase != .ready &&
            (connection.battery != nil || connection.temperature != nil || connection.thresholds != nil ||
             connection.activity != nil || !connection.deviceInformation.isEmpty)
    }

    private func card<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline).accessibilityAddTraits(.isHeader) }
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func valueRow(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value).fontWeight(.semibold).textSelection(.enabled)
            }
            .fixedSize(horizontal: true, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Text(value).fontWeight(.semibold).textSelection(.enabled)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func receivedTime(_ date: Date, title: String) -> some View {
        Text("\(title): \(date.formatted(date: .omitted, time: .standard))")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func channel(_ name: String, characteristic: QKCharacteristic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(name): \(connection.enabledNotificationIDs.contains(characteristic.id) ? "Subscribed" : "Pending")")
                .font(.subheadline.weight(.semibold))
            Text(characteristic.uuid.uuidString).font(.caption.monospaced()).textSelection(.enabled)
            Text(characteristic.propertySummary).font(.caption).foregroundStyle(.secondary)
        }
    }
}
