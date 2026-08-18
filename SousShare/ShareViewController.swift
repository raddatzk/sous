import SousKit
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What happens when a recipe page is shared into Sous.
///
/// The extension shows what it read and waits: a recipe off a web page is a
/// draft — the title is often the site's headline, the yield a guess — and
/// nobody wants a collection filling up with pages they only glanced at.
///
/// It cannot hand the job to the app, because an extension is not allowed to
/// open its own app, so it does the saving itself. Which is why the store
/// lives in an app group both sides can reach.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let hosting = UIHostingController(
            rootView: ShareView(model: model) { [weak self] in self?.finish() }
        )
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        Task {
            await model.read(items: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// The state of one shared page.
@MainActor
@Observable
final class ShareModel {
    enum State {
        case reading
        case found(recipe: Recipe, images: [Data])
        case saving
        case saved(String)
        case failed(String)
    }

    private(set) var state: State = .reading

    func read(items: [NSExtensionItem]) async {
        guard let url = await Self.sharedURL(in: items) else {
            state = .failed("Es wurde keine Adresse mitgeschickt.")
            return
        }
        guard ModelContainer.hasSharedContainer else {
            // Saving into the extension's own container would look like
            // success and put the recipe where the app never looks.
            state = .failed("Sous kann den gemeinsamen Speicher nicht öffnen.")
            return
        }

        do {
            let draft = try await RecipeWebImporter().draft(from: url)
            state = .found(recipe: draft.recipe, images: draft.images)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func save(_ recipe: Recipe, images: [Data]) async {
        state = .saving
        do {
            let container = try ModelContainer.sousContainer()
            let saved = try await RecipeWebImporter.save(recipe, images: images, into: container)
            state = .saved(saved.title)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The first web address among the shared items. Safari sends a URL;
    /// other apps sometimes send one as plain text.
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

/// The card over the page: what was read, and whether to keep it.
struct ShareView: View {
    @Bindable var model: ShareModel
    let onFinish: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            card
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.25))
        .animation(.easeInOut(duration: 0.2), value: label)
    }

    @ViewBuilder
    private var card: some View {
        VStack(spacing: 18) {
            switch model.state {
            case .reading:
                ProgressView()
                Text("Seite wird gelesen …").foregroundStyle(.secondary)

            case .found(let recipe, let images):
                preview(recipe, images: images)
                HStack(spacing: 12) {
                    Button("Abbrechen", action: onFinish)
                        .buttonStyle(.bordered)
                    Button("Sichern") {
                        Task { await model.save(recipe, images: images) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)

            case .saving:
                ProgressView()
                Text("Wird gesichert …").foregroundStyle(.secondary)

            case .saved(let title):
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("„\(title)“ ist in Sous.")
                    .multilineTextAlignment(.center)
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
        .padding(24)
        .frame(maxWidth: 340)
        .background(.background, in: .rect(cornerRadius: 22))
        .padding(24)
    }

    /// Enough of the recipe to tell whether the right thing was read.
    @ViewBuilder
    private func preview(_ recipe: Recipe, images: [Data]) -> some View {
        VStack(spacing: 12) {
            if let data = images.first, let image = Image(data: data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 12))
            }
            Text(recipe.title)
                .font(.system(.title3, design: .serif, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text(facts(of: recipe))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !recipe.categories.isEmpty {
                Text(recipe.categories.prefix(3).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
        }
    }

    private func facts(of recipe: Recipe) -> String {
        var parts = [
            "\(recipe.servings) Portionen",
            "\(recipe.ingredients.count) Zutaten",
            "\(recipe.steps.count) Schritte",
        ]
        if let minutes = recipe.elapsedTimeSeconds.map({ $0 / 60 }) {
            parts.append("\(minutes) Min.")
        }
        return parts.joined(separator: " · ")
    }

    /// Only used to animate between states.
    private var label: String {
        switch model.state {
        case .reading: "reading"
        case .found(let recipe, _): recipe.title
        case .saving: "saving"
        case .saved: "saved"
        case .failed: "failed"
        }
    }
}

private extension Image {
    init?(data: Data) {
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
    }
}
