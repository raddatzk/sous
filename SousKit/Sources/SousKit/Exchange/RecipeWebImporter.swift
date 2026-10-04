import Foundation

/// Fetches a recipe page and reads the recipe out of it.
///
/// Nothing is stored here. A recipe off a web page is a draft — the title is
/// often the site's headline and the yield a guess — so it goes to the
/// editor first and into the collection only if the cook says so.
public struct RecipeWebImporter: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Reads the page and returns the recipe with its pictures, unsaved.
    public func draft(from url: URL) async throws -> (recipe: Recipe, images: [Data]) {
        let html = try await html(from: url)
        let found = try RecipeWebImport.extract(from: html, url: url)

        var images: [Data] = []
        for imageURL in found.imageURLs {
            // A missing picture is not worth failing the import over.
            if let data = try? await data(from: imageURL) { images.append(data) }
        }
        return (found.recipe, images)
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
