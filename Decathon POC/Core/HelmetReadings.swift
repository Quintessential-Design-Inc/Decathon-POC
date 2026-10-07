import Foundation

enum HelmetBatteryCategory: String {
    case full = "FULL BATTERY", medium = "MEDIUM BATTERY", low = "LOW BATTERY"

    var title: String {
        switch self {
        case .full: "Full"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}

struct HelmetBatteryReading {
    let percentage: Int
    let category: HelmetBatteryCategory
    let receivedAt: Date
    let fromRead: Bool
}

struct HelmetTemperatureReading {
    let celsius: Double
    let receivedAt: Date
}

enum HelmetActivity: String {
    case active = "ACT", inactive = "INACT"
    var title: String { self == .active ? "Active" : "Inactive" }
}

struct HelmetCrashThresholds {
    let majorG: Int
    let minorG: Int
    let receivedAt: Date

    init?(data: Data, receivedAt: Date) {
        guard data.count == 10 else { return nil }
        let bytes = Array(data)
        majorG = Int(bytes[1])
        minorG = Int(bytes[2])
        self.receivedAt = receivedAt
    }
}

/// Only documented complete messages produce readings; unknown alerts stay diagnostic text.
enum HelmetAlert {
    case battery(Int, HelmetBatteryCategory, Double)
    case activity(HelmetActivity)
    case temperature(Double)

    init?(data: Data) {
        guard data.count <= 512, let raw = String(data: data, encoding: .utf8) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activity = HelmetActivity(rawValue: text) {
            self = .activity(activity)
            return
        }
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if fields.count == 3, let category = HelmetBatteryCategory(rawValue: fields[0]),
           let percentage = Int(fields[1]), (0...100).contains(percentage),
           let temperature = Double(fields[2]), temperature.isFinite {
            self = .battery(percentage, category, temperature)
            return
        }
        if text.hasPrefix("Temp:") {
            let fields = text.dropFirst(5).split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 10 else { return nil }
            let values = fields.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard values.count == 10, values.allSatisfy(\.isFinite), let latest = values.last else { return nil }
            self = .temperature(latest)
            return
        }
        return nil
    }
}

enum HelmetDeviceInfoField: String, CaseIterable, Identifiable {
    case firmware = "Firmware version", hardware = "Hardware version", model = "Model", serial = "Serial number"
    var id: Self { self }
    var uuidString: String {
        switch self {
        case .firmware: "2A26"
        case .hardware: "2A27"
        case .model: "2A24"
        case .serial: "2A25"
        }
    }
}
