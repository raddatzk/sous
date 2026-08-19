import CryptoKit
import Foundation

/// Whether a recipe's ingredients or instructions have changed since
/// something was cached against them — the same "derive an identity from
/// content" idea as `StableID`, but content-only: no position, and no
/// stamping into UUID shape, since this is compared as a plain string, not
/// used for SwiftUI identity.
enum RecipeContentHash {
    static func hash(for recipe: Recipe) -> String {
        let digest = SHA256.hash(data: Data("\(recipe.ingredientsText)\n\(recipe.instructionsText)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
