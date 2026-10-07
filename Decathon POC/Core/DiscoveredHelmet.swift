import Foundation
import QuinKitBLE

/// The documented Decathlon manufacturer value includes the two-byte company ID.
struct DecathlonAdvertisement {
    let macAddress: String
    let batteryPercentage: Int?
    let storedEventCount: Int

    init?(manufacturerData: Data?) {
        guard let manufacturerData, manufacturerData.count >= 14 else { return nil }
        let bytes = Array(manufacturerData)
        let companyID = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard companyID == 0x0ED6,
              Array(bytes[8...11]) == [0x08, 0x08, 0x04, 0xB3] else { return nil }

        macAddress = bytes[2...7].map { String(format: "%02X", $0) }.joined(separator: ":")
        batteryPercentage = bytes[12] <= 100 ? Int(bytes[12]) : nil
        storedEventCount = Int(bytes[13])
    }
}

struct DiscoveredHelmet: Identifiable {
    let scanResult: QKScanResult
    let advertisement: DecathlonAdvertisement

    var id: UUID { scanResult.id }
    var lastSeen: Date { scanResult.discoveredAt }

    var name: String {
        [scanResult.name, scanResult.localName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "QUIN PRO"
    }

    init?(scanResult: QKScanResult) {
        guard let advertisement = DecathlonAdvertisement(
            manufacturerData: scanResult.advertisementData.manufacturerData
        ) else { return nil }
        self.scanResult = scanResult
        self.advertisement = advertisement
    }
}
