import SousKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What happens when a recipe page is shared into Sous.
///
/// The extension does the whole import itself rather than handing the URL to
/// the app: sharing should be one gesture that ends where it started, in
/// Safari, with the recipe already in the collection. That is only possible
/// because the store lives in the app group both sides can reach.
final class ShareViewController: UIViewController {
    private var model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let view = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.finish()
        })
        addChild(view)
        view.view.frame = self.view.bounds
        view.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.view.backgroundColor = .clear
        self.view.addSubview(view.view)
        view.didMove(toParent: self)

        Task { await model.run(items: extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// The state of one shared page, from "reading" to a recipe or a reason.
@MainActor
@Observable
final class ShareModel {
    enum State {
        case working(String)
        case done(Recipe)
        case failed(String)
    }

    private(set) var state: State = .working("Seite wird gelesen …")

    func run(items: [NSExtensionItem]) async {
        do {
            guard let url = await Self.sharedURL(in: items) else {
                state = .failed("Es wurde keine Adresse mitgeschickt.")
                return
            }

            let importer = try RecipeWebImporter()
            state = .working("Rezept wird gesucht …")
            let recipe = try await importer.importRecipe(from: url)
            state = .done(recipe)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The first web address among the shared items. Safari sends a URL;
    /// other apps sometimes send it as plain text.
    private static func sharedURL(in items: [NSExtensionItem]) async -> URL? {
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
}

/// A sheet the size of a card: what was found, and a way out.
struct ShareView: View {
    @Bindable var model: ShareModel
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            switch model.state {
            case .working(let message):
                ProgressView()
                Text(message)
                    .foregroundStyle(.secondary)

            case .done(let recipe):
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(spacing: 4) {
                    Text(recipe.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(summary(of: recipe))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Fertig", action: onFinish)
                    .buttonStyle(.borderedProminent)

            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(reason)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Schließen", action: onFinish)
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.2))
    }

    /// Enough for the sharer to see that the right thing was read.
    private func summary(of recipe: Recipe) -> String {
        var parts = ["\(recipe.ingredients.count) Zutaten", "\(recipe.steps.count) Schritte"]
        if let minutes = recipe.elapsedTimeSeconds.map({ $0 / 60 }) {
            parts.append("\(minutes) Min.")
        }
        return parts.joined(separator: " · ")
    }
}
