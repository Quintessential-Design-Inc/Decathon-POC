import SwiftUI

struct LEDColorCard: View {
    let connection: HelmetConnection
    @State private var red = "0"
    @State private var green = "0"
    @State private var blue = "0"
    @FocusState private var focusedChannel: Channel?

    private enum Channel: Hashable { case red, green, blue }
    private var color: HelmetRGBColor? { HelmetRGBColor(red: red, green: green, blue: blue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LED colour").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if connection.ledColor.isSending {
                    ProgressView().accessibilityLabel("Setting LED colour")
                }
            }
            HStack(spacing: 12) {
                channelField("Red", text: $red, channel: .red)
                channelField("Green", text: $green, channel: .green)
                channelField("Blue", text: $blue, channel: .blue)
            }
            .disabled(!connection.canSetLEDColor)

            Text("Enter 0–100 for each channel. Set all three to 0 to clear the colour.")
                .font(.footnote).foregroundStyle(.secondary)
            if color == nil {
                Text("Each value must be a whole number from 0 to 100.")
                    .font(.footnote).foregroundStyle(.red)
            }
            POCActionButton(title: "Set LED colour", systemImage: "lightbulb", prominence: .secondary) {
                guard let color else { return }
                focusedChannel = nil
                Task { await connection.setLEDColor(color) }
            }
            .disabled(color == nil || !connection.canSetLEDColor)
            Text("Colour changes are ignored while charging. Crash indications can override or alternate with the chosen colour.")
                .font(.footnote).foregroundStyle(.secondary)
            if let message = connection.ledColor.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedChannel = nil }
            }
        }
        .onChange(of: connection.phase) { _, phase in
            if phase != .ready { focusedChannel = nil }
        }
        .onChange(of: connection.helmet?.id) { _, _ in
            red = "0"
            green = "0"
            blue = "0"
            focusedChannel = nil
        }
    }

    private func channelField(_ title: String, text: Binding<String>, channel: Channel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            TextField("0–100", text: text)
                .font(.title3).monospacedDigit()
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .focused($focusedChannel, equals: channel)
                .accessibilityLabel("\(title) intensity")
                .accessibilityHint("Enter a whole number from 0 to 100")
        }
        .frame(maxWidth: .infinity)
    }
}
