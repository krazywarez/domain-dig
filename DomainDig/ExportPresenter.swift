import SwiftUI
import UIKit

enum ExportPresenter {
    static func share(filename: String, contents: String) {
        share(filename: filename, data: Data(contents.utf8))
    }

    static func share(filename: String, data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }

        let activityController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.keyWindow?.rootViewController else {
            return
        }

        var presenter = rootViewController
        while let presentedViewController = presenter.presentedViewController {
            presenter = presentedViewController
        }

        activityController.popoverPresentationController?.sourceView = presenter.view
        presenter.present(activityController, animated: true)
    }
}

/// The export menu's entries: text for everyone, the other formats with
/// advanced exports, and otherwise disabled Pro upsells in their place.
struct ExportFormatButtons: View {
    let share: (DomainExportFormat) -> Void
    /// Labels the entries as exporting a batch.
    var batch = false

    var body: some View {
        let noun = batch ? " Batch" : ""
        Button("Export\(noun) TXT") {
            share(.text)
        }
        if FeatureAccessService.hasAccess(to: .advancedExports) {
            ForEach(Self.advancedFormats, id: \.label) { format in
                Button("Export\(noun) \(format.label)") {
                    share(format.format)
                }
            }
        } else {
            ForEach(Self.advancedFormats, id: \.label) { format in
                // Inert: disabled Pro upsell affordance.
                Button(batch ? "Batch \(format.label) • Available in Pro" : "\(format.label) Export • Available in Pro") {}
                    .disabled(true)
            }
        }
    }

    private static let advancedFormats: [(label: String, format: DomainExportFormat)] = [
        ("CSV", .csv), ("JSON", .json), ("Markdown", .markdown), ("PDF", .pdf),
    ]
}
