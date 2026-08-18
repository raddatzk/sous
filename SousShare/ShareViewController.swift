import UIKit
import UniformTypeIdentifiers

/// What happens when a recipe page is shared into Sous.
///
/// The extension does not import anything. It hands the address to the app
/// and gets out of the way: a recipe read off a page needs looking over
/// before it joins the collection — the title is often the site's headline,
/// the yield a guess — and that is a job for the app's editor, not for a
/// sheet on top of Safari.
///
/// It also keeps this side free of the database entirely, which means no
/// shared container and no entitlement to go wrong.
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handOver() }
    }

    private func handOver() async {
        guard let url = await sharedURL() else {
            return finish()
        }
        var components = URLComponents()
        components.scheme = "sous"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]

        if let target = components.url {
            _ = await extensionContext?.open(target)
        }
        finish()
    }

    /// The first web address among the shared items. Safari sends a URL;
    /// other apps sometimes send one as plain text.
    private func sharedURL() async -> URL? {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(
                   forTypeIdentifier: UTType.url.identifier
               ) as? URL {
                return url
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try? await provider.loadItem(
                   forTypeIdentifier: UTType.plainText.identifier
               ) as? String,
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.scheme?.hasPrefix("http") == true {
                return url
            }
        }
        return nil
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
