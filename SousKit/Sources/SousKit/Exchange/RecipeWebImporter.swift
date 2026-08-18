import Foundation
import SwiftData

/// Fetches a recipe page and puts what it finds into the collection.
///
/// Its own type rather than a method on ``RecipeLibrary``: the share
/// extension has no library, no views and no main actor to speak of — it
/// needs the store and nothing else.
public struct RecipeWebImporter: Sendable {
    private let store: any RecipeStore
    private let imageStore: any RecipeImageStore
    private let session: URLSession

    public init(store: any RecipeStore, imageStore: any RecipeImageStore, session: URLSession = .shared) {
        self.store = store
        self.imageStore = imageStore
        self.session = session
    }

    /// Opens the shared store, which is what an extension wants — and
    /// refuses to run without it rather than saving where nobody looks.
    public init(session: URLSession = .shared) throws {
        let container = try ModelContainer.sousContainer(requiringSharedStore: true)
        self.init(
            store: SwiftDataRecipeStore(modelContainer: container),
            imageStore: SwiftDataRecipeImageStore(modelContainer: container),
            session: session
        )
    }

    /// Reads the page, stores the recipe, and returns it as stored.
    @discardableResult
    public func importRecipe(from url: URL) async throws -> Recipe {
        let html = try await html(from: url)
        let found = try RecipeWebImport.extract(from: html, url: url)

        var recipe = try await store.save(found.recipe)
        var ids: [UUID] = []
        for imageURL in found.imageURLs {
            // A missing picture is not worth failing the import over.
            guard let data = try? await self.data(from: imageURL),
                  let id = try? await imageStore.add(data, to: recipe.id)
            else { continue }
            ids.append(id)
        }
        if !ids.isEmpty {
            recipe.imageIDs = ids
            recipe = try await store.save(recipe)
        }
        return recipe
    }

    private func html(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        // Sites serve their structured data to browsers; some serve a
        // consent wall or nothing at all to anything else.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebImportError.badResponse(http.statusCode)
        }
        // Most recipe sites are UTF-8; the rest are almost always Latin-1.
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { throw WebImportError.unreadablePage }
        return html
    }

    private func data(from url: URL) async throws -> Data {
        let (data, _) = try await session.data(from: url)
        return data
    }
}

public enum WebImportError: Error, LocalizedError, Sendable {
    case badResponse(Int)
    case unreadablePage

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code): "Die Seite antwortete mit Fehler \(code)."
        case .unreadablePage: "Die Seite konnte nicht gelesen werden."
        }
    }
}
