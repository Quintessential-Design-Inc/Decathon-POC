import SwiftUI

/// Native glass action styling shared by the home screen and future device screens.
struct POCActionButton: View {
    @Environment(\.isEnabled) private var isEnabled

    enum Prominence {
        case primary
        case secondary
    }

    let title: String
    let systemImage: String
    var prominence: Prominence = .primary
    let action: () -> Void

    var body: some View {
        switch prominence {
        case .primary:
            button
                .foregroundStyle(isEnabled ? Color.black : Color.primary)
                .buttonStyle(.glassProminent)
        case .secondary:
            button
                .buttonStyle(.glass)
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
        }
        .controlSize(.large)
    }
}
