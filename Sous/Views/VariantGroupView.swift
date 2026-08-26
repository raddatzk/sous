import SousKit
import SwiftUI

/// The versions of one dish side by side, with what tells them apart.
///
/// The one thing no single recipe can show, and the reason a group has a page
/// at all: the question this screen answers is which of the five to cook
/// tonight. Everything on it is derived from the members when it is drawn —
/// the numbers from the same nutrition cache the recipe page reads, the
/// differences from the ingredient lists — which is what lets the screen be
/// rich while the stored group stays a title.
///
/// Nothing here plans, buys or cooks. Those all need a recipe, and a group is
/// not one; the way to them is through a member, which is exactly one tap
/// away in every column.
struct VariantGroupView: View {
    let group: VariantGroup

    @Environment(RecipeLibrary.self) private var library
    @Environment(NutritionLibrary.self) private var nutritionLibrary
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(RecipeSelection.self) private var selection

    @State private var members: [Recipe] = []
    /// Kilocalories per portion per member, and whether the figure covers
    /// every accountable ingredient — an incomplete one is still shown, but
    /// never naked. Same rule as the list's rows.
    @State private var kcal: [UUID: (value: Int, isComplete: Bool)] = [:]
    @State private var isRenaming = false
    @State private var newTitle = ""
    @State private var isConfirmingDissolve = false
    @State private var isAddingMember = false

    /// The width of one column. Wide enough for "Chili vegetarisch" on two
    /// lines and an amount beside a unit, narrow enough that two of them and
    /// the labels very nearly fit across a phone.
    ///
    /// Nearly, not quite: past two variants this is a table, and a table
    /// scrolls sideways. Squeezing the columns until five fit would make
    /// every one of them unreadable to save a gesture.
    private static let columnWidth: CGFloat = 150
    private static let labelWidth: CGFloat = 110

    private var comparison: VariantComparison {
        VariantComparison.make(of: members, catalog: catalog.catalog)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if members.count < 2 {
                    // Everything below compares, and there is nothing to
                    // compare. Reached by deleting a sibling while this page
                    // is open, which is ordinary rather than exceptional.
                    ContentUnavailableView(
                        "Nur noch eine Variante",
                        systemImage: "square.on.square",
                        description: Text("Diese Gruppe hat nichts mehr, was sie vergleichen könnte.")
                    )
                } else {
                    table
                    footer
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(group.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { groupToolbar }
        .sheet(isPresented: $isAddingMember) {
            VariantJoinPicker(target: .group(group))
        }
        .task(id: group.id) { await load() }
        // The members are recipes like any other and can be edited, deleted
        // or restored from anywhere else in the app while this page is up.
        .onChange(of: library.recipes) { Task { await load() } }
        .alert("Gruppe umbenennen", isPresented: $isRenaming) {
            TextField("Name des Gerichts", text: $newTitle)
            Button("Abbrechen", role: .cancel) {}
            Button("Umbenennen") {
                Task { await library.renameVariantGroup(group, to: newTitle) }
            }
        } message: {
            Text("Der Name steht über den Varianten und findet sie in der Suche.")
        }
        .confirmationDialog(
            "Gruppe auflösen?",
            isPresented: $isConfirmingDissolve,
            titleVisibility: .visible
        ) {
            Button("Auflösen", role: .destructive) {
                Task { await library.dissolveVariantGroup(group.id) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Rezepte bleiben alle erhalten und stehen danach einzeln in der Liste.")
        }
    }

    // MARK: - Header

    /// The name is in the navigation bar on the phone and nowhere at all on
    /// the Mac, where the window has no title of its own — so the page says
    /// it only where nothing else does.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(macOS)
            Text(group.title)
                .font(SousStyle.recipeTitle)
            #endif
            Text(members.count == 1 ? "1 Variante" : "\(members.count) Varianten")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The comparison

    private var table: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: Self.labelWidth, height: 1)
                    ForEach(members) { member in
                        memberHeader(member)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)

                attributeRow("Portionen") { "\($0.servings)" }
                attributeRow("Zeit") { recipe in
                    recipe.elapsedTimeSeconds.map { "\($0 / 60) Min." } ?? "—"
                }
                attributeRow("Pro Portion") { recipe in
                    guard let entry = kcal[recipe.id] else { return "—" }
                    return entry.isComplete ? "\(entry.value) kcal" : "≈ \(entry.value) kcal"
                }

                if !comparison.rows.isEmpty {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("Unterschiede")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: Self.labelWidth, alignment: .leading)
                    }
                    ForEach(comparison.rows) { row in
                        differenceRow(row)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func memberHeader(_ member: Recipe) -> some View {
        Button {
            open(member)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(member.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                HStack(spacing: 5) {
                    if member.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .imageScale(.small)
                    }
                    if member.wantToCook {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(.tint)
                            .imageScale(.small)
                    }
                }
            }
            .frame(width: Self.columnWidth, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func attributeRow(
        _ label: String,
        value: @escaping (Recipe) -> String
    ) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            ForEach(members) { member in
                Text(value(member))
                    .font(.subheadline)
                    .frame(width: Self.columnWidth, alignment: .leading)
            }
        }
    }

    /// One ingredient the versions disagree about.
    ///
    /// A missing line reads as a dash rather than as an empty cell: the
    /// absence *is* the difference, and an empty cell looks like a figure
    /// nobody has worked out yet.
    private func differenceRow(_ row: VariantComparison.Row) -> some View {
        GridRow {
            Text(row.title)
                .font(.subheadline)
                .frame(width: Self.labelWidth, alignment: .leading)
            ForEach(members) { member in
                Group {
                    if let ingredient = row.ingredients[member.id] {
                        IngredientLineView(ingredient: ingredient)
                            .font(.subheadline)
                    } else {
                        Text("—")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: Self.columnWidth, alignment: .leading)
            }
        }
    }

    /// What the versions have in common, counted rather than listed.
    ///
    /// Without it, two variants that differ in one line look like two
    /// unrelated recipes that happen to share a name.
    @ViewBuilder
    private var footer: some View {
        if comparison.sharedCount > 0 {
            Text(
                comparison.sharedCount == 1
                    ? "1 weitere Zutat ist in allen Varianten gleich."
                    : "\(comparison.sharedCount) weitere Zutaten sind in allen Varianten gleich."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var groupToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("Mehr", systemImage: "ellipsis.circle") {
                // A recipe that was written separately and turns out to be
                // another version of this dish. Nothing is copied — it keeps
                // everything it had and gains a sibling.
                Button("Rezept aufnehmen", systemImage: "rectangle.stack.badge.plus") {
                    isAddingMember = true
                }
                Button("Umbenennen", systemImage: "pencil") {
                    newTitle = group.title
                    isRenaming = true
                }
                Divider()
                // Not destructive to the recipes, and the dialog says so —
                // but it is the one thing on this page that cannot be undone
                // with a second tap.
                Button("Gruppe auflösen", systemImage: "square.on.square.slash") {
                    isConfirmingDissolve = true
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        members = await library.variantMembers(of: group.id)
        // One cache read per member — the same call the recipe page makes,
        // in a loop, because nutrition is keyed per recipe and variants
        // compute independently.
        var figures: [UUID: (value: Int, isComplete: Bool)] = [:]
        for member in members {
            guard let nutrition = await nutritionLibrary.nutrition(for: member),
                  nutrition.coverage.includedCount > 0
            else { continue }
            figures[member.id] = (
                Int(nutrition.perPortion.kcal.rounded()),
                nutrition.coverage.isComplete
            )
        }
        kcal = figures
    }

    /// Opens one of the versions.
    ///
    /// Through the selection on both platforms: the Mac swaps the column,
    /// the phone swaps what the list pushed. Either way the recipe lands
    /// where a recipe belongs, with everything a recipe page can do —
    /// planning it, buying for it, cooking it — which is the point of having
    /// come here to choose one.
    private func open(_ member: Recipe) {
        selection.target = .recipe(member)
        selection.plannedEntryID = nil
    }
}
