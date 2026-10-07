import CoreBluetooth
import Foundation
import QuinKitBLE

/// Resolve the guide's shorthand against discovered UUIDs, never a fabricated base UUID.
struct DecathlonProfile {
    let data: QKCharacteristic
    let alerts: QKCharacteristic

    var dataWriteType: CBCharacteristicWriteType {
        data.supportsWriteWithResponse ? .withResponse : .withoutResponse
    }

    init(services: [QKService]) throws {
        let dataServices = services.filter {
            $0.uuid.data.count == 16 && $0.uuid.uuidString.uppercased().hasPrefix("8925D23D-")
        }
        guard dataServices.count == 1, let dataService = dataServices.first else {
            throw ProfileError("Expected one data service beginning 8925D23D; found \(dataServices.count).")
        }

        data = try Self.unique(
            dataService.characteristics.filter { Self.matches($0.uuid, code: "6166") },
            name: "Offline data (6166)"
        )
        // The alert channel may be under a separate vendor service. A standard
        // Bluetooth service must never qualify just because a UUID contains 1002.
        alerts = try Self.unique(
            services.filter { $0.uuid.data.count == 16 }
                .flatMap(\.characteristics)
                .filter { Self.matches($0.uuid, code: "1002") },
            name: "Alerts (1002)"
        )

        guard data.isWritable, data.supportsValueUpdates else {
            throw ProfileError("Offline data \(data.uuid.uuidString) must support writing and notifications or indications.")
        }
        guard alerts.isReadable, alerts.isWritable, alerts.supportsValueUpdates else {
            throw ProfileError("Alerts \(alerts.uuid.uuidString) must support reading, writing, and notifications or indications.")
        }
    }

    private static func matches(_ uuid: CBUUID, code: String) -> Bool {
        let value = uuid.uuidString.uppercased()
        if value.count == 4 { return value == code }
        // Vendor shorthand occupies the low 16 bits of the first UUID field.
        // Keep the actual discovered UUID and reject multiple candidates.
        guard uuid.data.count == 16, let firstField = value.split(separator: "-").first else { return false }
        return firstField.count == 8 && firstField.hasSuffix(code)
    }

    static func readableConfiguration(in services: [QKService], alerts: QKCharacteristic) throws -> QKCharacteristic {
        let candidates = services.filter { $0.uuid == alerts.serviceUUID }
            .flatMap(\.characteristics).filter { matches($0.uuid, code: "1001") }
        let configuration = try unique(candidates, name: "Configuration (1001)")
        guard configuration.isReadable else { throw ProfileError("Configuration is not readable.") }
        return configuration
    }

    private static func unique(_ candidates: [QKCharacteristic], name: String) throws -> QKCharacteristic {
        guard candidates.count == 1, let characteristic = candidates.first else {
            throw ProfileError("\(name): expected one characteristic; found \(candidates.count). Check the discovered UUIDs against the firmware profile.")
        }
        return characteristic
    }
}

struct ProfileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension QKCharacteristic {
    var propertySummary: String {
        var names: [String] = []
        if isReadable { names.append("Read") }
        if supportsWriteWithResponse { names.append("Write") }
        if supportsWriteWithoutResponse { names.append("Write without response") }
        if isNotifiable { names.append("Notify") }
        if isIndicatable { names.append("Indicate") }
        return names.isEmpty ? "No supported operations" : names.joined(separator: " · ")
    }
}
