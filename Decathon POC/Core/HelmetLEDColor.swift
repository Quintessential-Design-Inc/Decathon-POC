import Foundation
import Observation

nonisolated struct HelmetRGBColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init?(red: String, green: String, blue: String) {
        guard let red = Self.channelValue(red),
              let green = Self.channelValue(green),
              let blue = Self.channelValue(blue) else { return nil }
        self.red = red
        self.green = green
        self.blue = blue
    }

    static func channelValue(_ text: String) -> UInt8? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt8(text), value <= 100 else { return nil }
        return value
    }

    var commandData: Data { Data([0x0B, red, green, blue]) }
    var isClear: Bool { red == 0 && green == 0 && blue == 0 }
    var summary: String { "R \(red), G \(green), B \(blue)" }
}

nonisolated private enum LEDColorReply {
    case accepted(HelmetRGBColor)
    case charging
}

/// Owns RGB command state and reply handling; BLE transport stays in the connection layer.
@MainActor
@Observable
final class HelmetLEDColor {
    private(set) var isSending = false
    private(set) var message: String?

    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var requestedColor: HelmetRGBColor?
    @ObservationIgnored private var continuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var reply: Result<LEDColorReply, Error>?
    @ObservationIgnored private var writeStarted = false
    @ObservationIgnored private var writeCompleted = false

    func send(_ color: HelmetRGBColor, write: @escaping @MainActor () async throws -> Void) async {
        guard !isSending, !Task.isCancelled else { return }
        let id = UUID()
        requestID = id
        requestedColor = color
        isSending = true
        message = nil
        reply = nil
        writeStarted = false
        writeCompleted = false

        await withTaskCancellationHandler {
            await withCheckedContinuation { pending in
                // Arm response handling first: RGB may arrive before the write acknowledgement.
                continuation = pending
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, self.requestID == id else { return }
                    if self.reply == nil {
                        self.reply = .failure(ProfileError("No RGB response within 5 seconds."))
                    }
                    // Keep competing commands blocked until the bounded BLE write also settles.
                    self.finishIfReady(id: id)
                }
                writeTask = Task { @MainActor [weak self] in
                    guard let self, self.requestID == id else { return }
                    do {
                        try Task.checkCancellation()
                        self.writeStarted = true
                        try await write()
                        try Task.checkCancellation()
                        guard self.requestID == id else { return }
                        self.writeCompleted = true
                        self.finishIfReady(id: id)
                    } catch {
                        self.finish(id: id, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    /// Consume only RGB notifications; battery, activity and TS replies keep their own handlers.
    @discardableResult
    func receive(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("RGB,") else { return false }
        guard let id = requestID, writeStarted, reply == nil else { return true }
        if text == "RGB,CHG" {
            reply = .success(.charging)
        } else {
            let fields = text.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let color = HelmetRGBColor(red: String(fields[1]), green: String(fields[2]), blue: String(fields[3])) else {
                reply = .failure(ProfileError("Malformed RGB response."))
                finishIfReady(id: id)
                return true
            }
            // The protocol has no request ID. A different colour cannot confirm this request.
            guard color == requestedColor else { return true }
            reply = .success(.accepted(color))
        }
        finishIfReady(id: id)
        return true
    }

    func clearSession() {
        if let id = requestID { finish(id: id, result: .failure(CancellationError())) }
        message = nil
    }

    private func cancel(id: UUID) {
        guard requestID == id else { return }
        reply = .failure(CancellationError())
        writeTask?.cancel()
        if writeStarted { finishIfReady(id: id) }
        else { finish(id: id, result: .failure(CancellationError())) }
    }

    private func finishIfReady(id: UUID) {
        guard writeCompleted, let reply else { return }
        finish(id: id, result: reply)
    }

    private func finish(id: UUID, result: Result<LEDColorReply, Error>) {
        guard requestID == id else { return }
        switch result {
        case .success(.accepted(let color)):
            message = color.isClear ? "LED colour cleared." : "Colour accepted: \(color.summary)."
        case .success(.charging):
            message = "Colour change ignored while charging. Unplug the helmet and try again."
        case .failure(let error):
            message = error is CancellationError ? "Colour change cancelled; its result is unconfirmed."
                : "Colour change unconfirmed. \(error.localizedDescription)"
        }
        let pending = continuation
        continuation = nil
        requestID = nil
        requestedColor = nil
        reply = nil
        writeStarted = false
        writeCompleted = false
        isSending = false
        writeTask?.cancel()
        writeTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        pending?.resume()
    }
}
