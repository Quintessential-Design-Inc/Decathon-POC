import Foundation

nonisolated struct CrashPacket: Sendable {
    static let endMarker = Data([0x01, 0x33, 0x55, 0xAA])
    let raw: Data
    let frame: Int
    let sensorType: UInt8
    let packetType: UInt8
    let crashID: String

    init(data: Data) throws {
        guard data.count == 126 else { throw ProfileError("Expected 126 bytes, received \(data.count).") }
        let bytes = Array(data)
        frame = Int(bytes[0])
        sensorType = bytes[1]
        packetType = bytes[2]
        crashID = bytes[3...5].map { String(format: "%02X", $0) }.joined()
        guard (1...64).contains(frame), sensorType == (frame <= 60 ? 0x01 : 0x02) else {
            throw ProfileError("Invalid frame number or sensor type.")
        }
        // Live/unknown payloads remain in the journal but cannot become offline events.
        guard [UInt8(0x43), 0x53, 0x63, 0x73, 0x83, 0x93].contains(packetType) else {
            throw ProfileError("Unexpected offline packet type \(String(format: "%02X", packetType)).")
        }
        raw = data
    }

    var classification: String {
        switch packetType {
        case 0x43: "Fall"
        case 0x53: "Crash after free-fall"
        case 0x63: "Impact"
        case 0x73: "Low-power fall"
        case 0x83: "Low-power crash after free-fall"
        case 0x93: "Low-power impact"
        default: "Unknown"
        }
    }
}

nonisolated struct CrashRecord: Sendable {
    let ordinal: Int
    let crashID: String
    let packetType: UInt8
    let classification: String
    let firstReceivedAt: Date
    var lastReceivedAt: Date
    var frames: [Int: Data] = [:]
    var duplicateCount = 0
    var conflictingFrames: Set<Int> = []
    var inconsistentHeader = false

    var missingFrames: [Int] { (1...64).filter { frames[$0] == nil } }
    var isComplete: Bool { frames.count == 64 && conflictingFrames.isEmpty && !inconsistentHeader }

    init(packet: CrashPacket, ordinal: Int, receivedAt: Date) {
        self.ordinal = ordinal
        crashID = packet.crashID
        packetType = packet.packetType
        classification = packet.classification
        firstReceivedAt = receivedAt
        lastReceivedAt = receivedAt
    }

    mutating func add(_ packet: CrashPacket, at date: Date) {
        lastReceivedAt = date
        if packet.packetType != packetType { inconsistentHeader = true }
        if let existing = frames[packet.frame] {
            if existing == packet.raw { duplicateCount += 1 }
            else { conflictingFrames.insert(packet.frame) }
        } else {
            frames[packet.frame] = packet.raw
        }
    }

    func decoded() -> DecodedCrashRecord {
        var imu: [DecodedIMUSample] = []
        var highG: [DecodedHighGSample] = []
        for frame in frames.keys.sorted() {
            guard let data = frames[frame] else { continue }
            let bytes = Array(data)
            if frame <= 60 {
                for sample in 0..<10 {
                    let offset = 6 + sample * 12
                    let gx = Self.signed16(bytes, offset), gy = Self.signed16(bytes, offset + 2), gz = Self.signed16(bytes, offset + 4)
                    let index = ((frame <= 30 ? frame - 1 : frame - 31) * 10) + sample
                    imu.append(DecodedIMUSample(
                        frame: frame, indexWithinBlock: index, block: frame <= 30 ? "pre" : "post",
                        secondsFromBlockStart: Double(index) / (frame <= 30 ? 104 : 52),
                        gxDPS: Double(gx) * 0.07, gyDPS: Double(gy) * 0.07, gzDPS: Double(gz) * 0.07,
                        axG: Double(Self.signed16(bytes, offset + 6)) * 0.000488,
                        ayG: Double(Self.signed16(bytes, offset + 8)) * 0.000488,
                        azG: Double(Self.signed16(bytes, offset + 10)) * 0.000488,
                        gyroMayBeUnmeasured: frame <= 30 && gx == 0 && gy == 0 && gz == 0
                    ))
                }
            } else {
                for sample in 0..<20 {
                    let offset = 6 + sample * 6
                    let index = (frame - 61) * 20 + sample
                    highG.append(DecodedHighGSample(
                        frame: frame, indexWithinBlock: index, secondsFromBlockStart: Double(index) / 1000,
                        ixG: Self.highG(bytes, offset), iyG: Self.highG(bytes, offset + 2), izG: Self.highG(bytes, offset + 4)
                    ))
                }
            }
        }
        return DecodedCrashRecord(crashID: crashID, ordinal: ordinal, imu: imu, highG: highG)
    }

    private static func signed16(_ bytes: [UInt8], _ offset: Int) -> Int16 {
        Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
    }

    private static func highG(_ bytes: [UInt8], _ offset: Int) -> Double {
        let raw = (Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)) & 0x0FFF
        return Double(raw >= 0x0800 ? raw - 0x1000 : raw) * 0.195
    }
}

nonisolated struct DecodedCrashRecord: Codable, Sendable {
    let crashID: String
    let ordinal: Int
    let imu: [DecodedIMUSample]
    let highG: [DecodedHighGSample]
}

nonisolated struct DecodedIMUSample: Codable, Sendable {
    let frame: Int
    let indexWithinBlock: Int
    let block: String
    let secondsFromBlockStart: Double
    let gxDPS: Double, gyDPS: Double, gzDPS: Double
    let axG: Double, ayG: Double, azG: Double
    let gyroMayBeUnmeasured: Bool
}

nonisolated struct DecodedHighGSample: Codable, Sendable {
    let frame: Int
    let indexWithinBlock: Int
    let secondsFromBlockStart: Double
    let ixG: Double, iyG: Double, izG: Double
}
