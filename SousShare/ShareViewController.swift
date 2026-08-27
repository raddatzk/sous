import CoreData
import SousKit
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What happens when a recipe page is shared into Sous.
///
/// The page is read and handed to the same editor the app uses, so what
/// arrives can be looked over and corrected before it is kept: a recipe off
/// the web is a draft — the title is often the site's headline, the yield a
/// guess, and the last step sometimes an advertisement.
///
/// The extension does this itself because iOS does not let it open its own
/// app. Which is why the store lives in an app group both sides can reach.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let root = ShareRootView(
            items: extensionContext?.inputItems as? [NSExtensionItem] ?? [],
            onFinish: { [weak self] in self?.finish() }
        )
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// Reads the shared page, then gets out of the editor's way.
struct ShareRootView: View {
    let items: [NSExtensionItem]
    let onFinish: () -> Void

    @State private var libraries: Libraries?
    @State private var message: String?

    var body: some View {
        Group {
            if let libraries {
                editor(libraries)
            } else if let message {
                card {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Schließen", action: onFinish)
                        .buttonStyle(.bordered)
                }
            } else {
                card {
                    ProgressView()
                    Text("Seite wird gelesen …").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sousScrim)
        .sousAppearance()
        .task { await start() }
    }

    /// The editor, presented the way the app presents it, so cancelling and
    /// saving behave the same on both sides.
    @ViewBuilder
    private func editor(_ libraries: Libraries) -> some View {
        @Bindable var library = libraries.recipes
        Color.clear
            .sheet(item: $library.editing) { draft in
                RecipeEditorView(recipe: draft) { edited in
                    await libraries.recipes.save(edited)
                }
                .environment(libraries.recipes)
                .environment(libraries.catalog)
                .environment(libraries.nutrition)
            }
            // Closing the editor — saved or not — ends the share. An
            // abandoned draft takes its downloaded pictures with it.
            .onChange(of: library.editing) { _, editing in
                guard editing == nil else { return }
                Task {
                    await libraries.recipes.discardUnsavedDraft()
                    onFinish()
                }
            }
    }

    @ViewBuilder
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 16) { content() }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.background, in: .rect(cornerRadius: 20))
    }

    private func start() async {
        guard libraries == nil, message == nil else { return }
        guard let url = await Self.sharedURL(in: items) else {
            message = "Es wurde keine Adresse mitgeschickt."
            return
        }
        do {
            // Saving into the extension's own container would look like
            // success and put the recipe where the app never looks.
            let container = try ModelContainer.sousContainer()
            // Local only, no mirroring: two processes syncing the same
            // store files would be two engines racing over one set of books,
            // inside a memory ceiling an import is happy to blow through.
            // The save lands in the store's history and the app exports it.
            let coreData = try SousPersistentContainer.make(mirroring: false)
            guard ModelContainer.hasSharedContainer else {
                message = "Sous kann den gemeinsamen Speicher nicht öffnen."
                return
            }
            let made = Libraries(container: container, coreData: coreData)
            await made.recipes.importFromWeb(url)
            guard made.recipes.editing != nil else {
                message = made.recipes.errorMessage
                    ?? "Auf dieser Seite wurde kein Rezept gefunden."
                return
            }
            libraries = made
        } catch {
            message = error.localizedDescription
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

/// What the editor needs from the shared store.
@MainActor
final class Libraries {
    let recipes: RecipeLibrary
    let catalog: IngredientCatalogLibrary
    /// Not for computing anything here — the editor's ingredient sheet shows
    /// and takes nutrition, and a shared recipe is checked in that same
    /// editor, so the extension has to be able to answer it too.
    let nutrition: NutritionLibrary

    /// Two containers: everything belonging to the household is in Core
    /// Data, while the nutrition and enrichment caches stay in SwiftData —
    /// both keyed to a content hash and cheaper to recompute than to sync.
    /// Both sit in the app group: saving into the extension's own would look
    /// like success and put the recipe where the app never looks.
    init(container: ModelContainer, coreData: NSPersistentContainer) {
        let nutritionStore = SwiftDataRecipeNutritionStore(modelContainer: container)
        let recipeStore = CoreDataRecipeStore(container: coreData)
        recipes = RecipeLibrary(
            store: recipeStore,
            imageStore: CoreDataRecipeImageStore(container: coreData),
            enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container),
            amountReviewStore: CoreDataRecipeAmountReviewStore(container: coreData)
        )
        // The extension never runs the migrations — it may well be the first
        // thing to open the store after an update. Writing a vocabulary entry
        // it has never seen is fine: the fold merges by key rather than
        // inserting, so whatever the app finds later joins this row instead of
        // doubling it.
        catalog = IngredientCatalogLibrary(
            store: CoreDataVocabularyStore(container: coreData),
            nutritionCache: nutritionStore
        )
        nutrition = NutritionLibrary(
            store: nutritionStore,
            recipeStore: recipeStore,
            catalogLibrary: catalog
        )
    }
}
