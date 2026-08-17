import SousKit
import SwiftUI

/// A recipe referenced by another one, shown as a row that opens it.
struct LinkedRecipeRow: View {
    let recipeID: UUID
    let onOpen: (Recipe) -> Void

    @Environment(RecipeLibrary.self) private var library
    @State private var recipe: Recipe?

    var body: some View {
        Button {
            if let recipe { onOpen(recipe) }
        } label: {
            HStack(spacing: 12) {
                if let imageID = recipe?.imageIDs.first {
                    RecipeImageView(imageID: imageID, thumbnail: true)
                        .frame(width: 44, height: 44)
                        .clipShape(.rect(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "square.stack")
                                .foregroundStyle(.secondary)
                        }
                }
                Text(recipe?.title ?? "…")
                    .font(SousStyle.recipeName)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .disabled(recipe == nil)
        .task(id: recipeID) { recipe = await library.recipe(id: recipeID) }
    }
}
