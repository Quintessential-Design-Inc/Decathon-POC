import SwiftUI

struct HelmetScanResultRow: View {
    let helmet: DiscoveredHelmet

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(helmet.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text("MAC: \(helmet.advertisement.macAddress)")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    battery
                    Spacer(minLength: 0)
                    eventCount
                }
                .fixedSize(horizontal: true, vertical: true)

                VStack(alignment: .leading, spacing: 16) {
                    battery
                    eventCount
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }

    private var battery: some View {
        metric("Battery", value: helmet.advertisement.batteryPercentage.map { "\($0)%" } ?? "Unavailable")
    }

    private var eventCount: some View {
        metric("Stored events", value: String(helmet.advertisement.storedEventCount))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
