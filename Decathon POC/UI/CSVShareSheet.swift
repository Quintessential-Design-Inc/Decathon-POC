import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// UIKit receives promised CSV bytes; the app creates no export file or archive.
struct CSVShareSheet: UIViewControllerRepresentable {
    let payload: SessionCSVPayload
    let completion: @MainActor (Bool, String?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let provider = NSItemProvider()
        provider.suggestedName = payload.filename
        let bytes = payload.data
        provider.registerDataRepresentation(forTypeIdentifier: UTType.commaSeparatedText.identifier, visibility: .all) { callback in
            callback(bytes, nil)
            return nil
        }
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        controller.completionWithItemsHandler = { _, completed, _, error in
            let message = error?.localizedDescription
            Task { @MainActor in completion(completed, message) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
