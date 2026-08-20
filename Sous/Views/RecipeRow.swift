import SousKit
import SwiftUI

/// One recipe as a card in the list: what it looks like, what it is called,
/// how long it takes, and what it is filed under.
///
/// The picture keeps its slot even when a recipe has none, so titles line up
/// down the list instead of stepping in and out. Time and categories share
/// one row of chips: they answer the same question — is this the right thing
/// to cook tonight — and separate lines for each would make every row tall
/// enough that only a handful fit on screen.
struct RecipeRow: View {
    let recipe: Recipe

    @Environment(RecipeLibrary.self) private var library
    /// Whether this recipe still has amount suggestions nobody has looked
    /// at — a plain, non-AI resolver read, cheap enough to run per row.
    @State private var needsAmountReview = false

    /// Enough to say what a recipe is; more would push the rows apart.
    private static let visibleCategories = 3

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(recipe.title)
                        .font(SousStyle.recipeName)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    markers
                }
                attributes
            }
        }
        .padding(.vertical, 6)
        .task(id: recipe.id) {
            needsAmountReview = await library.needsAmountReview(recipe)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let imageID = recipe.imageIDs.first {
                RecipeImageView(imageID: imageID, thumbnail: true)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "fork.knife")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        // Smaller on the Mac: 68 points is right for a thumb-sized row on a
        // phone and takes up most of a sidebar's width.
        #if os(macOS)
        .frame(width: 44, height: 44)
        #else
        .frame(width: 68, height: 68)
        #endif
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var markers: some View {
        if recipe.isFavorite {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .imageScale(.small)
        }
        if recipe.wantToCook {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
                .imageScale(.small)
        }
        if needsAmountReview {
            Image(systemName: "text.badge.checkmark")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
    }

    /// The time first — it decides whether a recipe fits the evening — then
    /// what it is filed under.
    @ViewBuilder
    private var attributes: some View {
        let shown = recipe.categories.prefix(Self.visibleCategories)
        let hidden = recipe.categories.count - shown.count
        if totalMinutes != nil || !shown.isEmpty {
            FlowLayout(spacing: 5, lineSpacing: 5) {
                if let minutes = totalMinutes {
                    chip("\(minutes) Min.", systemImage: "clock", tinted: false)
                }
                ForEach(Array(shown), id: \.self) { category in
                    chip(category)
                }
                if hidden > 0 {
                    chip("+\(hidden)")
                }
            }
        }
    }

    private func chip(
        _ text: String,
        systemImage: String? = nil,
        tinted: Bool = true
    ) -> some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            tinted ? AnyShapeStyle(.tint.opacity(SousStyle.chipTint)) : AnyShapeStyle(Color.sousField),
            in: .capsule
        )
        .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }

    /// The time it takes from start to finish — the number that answers
    /// "can I have this tonight".
    private var totalMinutes: Int? {
        recipe.elapsedTimeSeconds.map { $0 / 60 }
    }
}
