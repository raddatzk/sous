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
    /// Which of the two shapes a recipe takes.
    ///
    /// Both live here rather than in two views, because the four status
    /// glyphs, the time and the categories are what a recipe is allowed to
    /// say about itself in a library — and two views would drift apart on
    /// that. Only the arrangement differs: the row lays it out beside the
    /// picture, the card under it.
    enum Layout {
        /// Picture at the left, everything else beside it.
        case row
        /// Picture on top, everything else under it — the shelf a wide
        /// library becomes.
        case card
    }

    let recipe: Recipe
    var layout: Layout = .row

    @Environment(RecipeLibrary.self) private var library
    @Environment(NutritionLibrary.self) private var nutritionLibrary
    /// Whether this recipe still has amount suggestions nobody has looked
    /// at — a plain, non-AI resolver read, cheap enough to run per row.
    @State private var needsAmountReview = false
    /// A cache read, same as `needsAmountReview` — cheap once nutrition has
    /// been computed for this recipe once.
    @State private var kcalPerPortion: Int?
    /// Whether that figure covers every accountable ingredient — an
    /// incomplete one is still shown, but never naked.
    @State private var kcalIsComplete = false
    /// Whether the catalog is missing any of this recipe's ingredients —
    /// the list-wide view of the same check the detail page's banner runs.
    @State private var needsIngredientReview = false

    /// Enough to say what a recipe is; more would push the rows apart.
    private static let visibleCategories = 3

    var body: some View {
        Group {
            switch layout {
            case .row: rowShape
            case .card: cardShape
            }
        }
        .task(id: recipe.id) {
            needsAmountReview = await library.needsAmountReview(recipe)
        }
        .task(id: recipe.id) {
            let nutrition = await nutritionLibrary.nutrition(for: recipe)
            // A figure no ingredient contributed to is no figure — showing
            // "0 kcal" for a recipe of unmatched lines would be the naked
            // number this chip is not allowed to be.
            if let nutrition, nutrition.coverage.includedCount > 0 {
                kcalPerPortion = Int(nutrition.perPortion.kcal.rounded())
                kcalIsComplete = nutrition.coverage.isComplete
            } else {
                kcalPerPortion = nil
            }
        }
        .task(id: recipe.id) {
            needsIngredientReview = await library.needsIngredientReview(recipe)
        }
    }

    private var rowShape: some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 7) {
                titleLine
                attributes
            }
        }
        .padding(.vertical, 6)
    }

    /// The picture first and large, then the name under it.
    ///
    /// Which is what a shelf is: you recognise the dish before you read it.
    /// Four to three rather than square — a photographed plate is wider than
    /// it is tall, and a square crop cuts the ends off it.
    private var cardShape: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { picture }
                .clipped()
            VStack(alignment: .leading, spacing: 7) {
                titleLine
                attributes
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        // Filling the cell rather than the content, so a row of cards has one
        // bottom edge: a name that wraps to two lines would otherwise leave
        // its neighbours' cards short, and the shelf ended up ragged along
        // every row.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.sousBackground)
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
    }

    /// The name, and what the four glyphs have to say beside it.
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(recipe.title)
                .font(SousStyle.recipeName)
                .lineLimit(2)
            Spacer(minLength: 0)
            markers
        }
    }

    /// The stored picture, or the same empty plate the row shows.
    ///
    /// The full image rather than the stored thumbnail, which is 400 pixels
    /// across — right for a 68-point row and soft blown up to a card three
    /// hundred points wide. A grid is lazy, so this is the handful on screen
    /// rather than the whole library.
    @ViewBuilder
    private var picture: some View {
        if let imageID = recipe.imageIDs.first {
            RecipeImageView(imageID: imageID)
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "fork.knife")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
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

    /// Labelled, not decorative: these four glyphs are the row's whole
    /// status vocabulary, and without names VoiceOver reads a row with a
    /// bookmark and a row without one identically.
    @ViewBuilder
    private var markers: some View {
        if recipe.isFavorite {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .imageScale(.small)
                .accessibilityLabel("Favorit")
        }
        if recipe.wantToCook {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
                .imageScale(.small)
                .accessibilityLabel("Will ich kochen")
        }
        if needsAmountReview {
            Image(systemName: "text.badge.checkmark")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .accessibilityLabel("Mengen zu prüfen")
        }
        if needsIngredientReview {
            Image(systemName: "text.book.closed")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .accessibilityLabel("Unbekannte Zutaten")
        }
    }

    /// The time first — it decides whether a recipe fits the evening — then
    /// what it is filed under.
    @ViewBuilder
    private var attributes: some View {
        let shown = recipe.categories.prefix(Self.visibleCategories)
        let hidden = recipe.categories.count - shown.count
        if totalMinutes != nil || kcalPerPortion != nil || !shown.isEmpty {
            FlowLayout(spacing: 5, lineSpacing: 5) {
                if let minutes = totalMinutes {
                    chip("\(minutes) Min.", systemImage: "clock")
                }
                // Marked when coverage is incomplete: the "≈" and the dashed
                // circle say "this is a floor, not the dish" without costing
                // the row a second line.
                if let kcalPerPortion {
                    chip(
                        kcalIsComplete ? "\(kcalPerPortion) kcal" : "≈ \(kcalPerPortion) kcal",
                        systemImage: kcalIsComplete ? nil : "circle.dashed"
                    )
                }
                // Each category keeps its own colour rather than sharing the
                // app's one accent — with several shown at once, a reader
                // tells them apart by colour before they have read the word.
                ForEach(Array(shown), id: \.self) { category in
                    chip(category, color: .sousCategory(category))
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
        color: Color? = nil
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
            color.map { AnyShapeStyle($0.opacity(SousStyle.chipTint)) } ?? AnyShapeStyle(Color.sousField),
            in: .capsule
        )
        .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }

    /// The time it takes from start to finish — the number that answers
    /// "can I have this tonight".
    private var totalMinutes: Int? {
        recipe.elapsedTimeSeconds.map { $0 / 60 }
    }
}
