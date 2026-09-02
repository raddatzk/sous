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
/// The two things a reader can want from a group.
///
/// Not stored anywhere, and not a property of the group: which one is right
/// depends on the door you came through, not on the dish. Storing it would
/// make the group a place with settings, and the whole arrangement rests on
/// the group being a title and nothing else.
enum VariantGroupMode: String, CaseIterable, Hashable {
    /// The versions as ordinary recipe rows — picture, name, categories,
    /// calories. What "which versions of this are there?" wants.
    case overview
    /// The table. What "which of these do I cook tonight?" wants.
    case comparison

    var title: String {
        switch self {
        case .overview: "Übersicht"
        case .comparison: "Vergleich"
        }
    }
}

struct VariantGroupView: View {
    let group: VariantGroup
    /// Which mode the page opens in, decided by whoever opened it: the list
    /// means "compare these", a recipe means "show me the others".
    var initialMode: VariantGroupMode = .comparison

    @Environment(RecipeLibrary.self) private var library
    @Environment(NutritionLibrary.self) private var nutritionLibrary
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(RecipeSelection.self) private var selection

    @State private var members: [Recipe] = []
    /// Per-portion figures per member, from the same cache the recipe page
    /// reads. The whole record rather than a kcal excerpt: the table shows
    /// the label's rows, and each needs its own number.
    @State private var nutrition: [UUID: RecipeNutrition] = [:]
    @State private var isRenaming = false
    @State private var newTitle = ""
    @State private var isConfirmingDissolve = false
    @State private var isAddingMember = false
    /// What the reader switched to, if they switched. `nil` means the page
    /// is still showing what it was opened for — a switch belongs to this
    /// visit and is not carried to the next one, or the door the reader came
    /// through would stop deciding anything.
    @State private var chosenMode: VariantGroupMode?

    private var mode: VariantGroupMode { chosenMode ?? initialMode }

    /// The width of one column. Wide enough for "Chili vegetarisch" on two
    /// lines and an amount beside a unit, narrow enough that two of them and
    /// the labels very nearly fit across a phone.
    ///
    /// Nearly, not quite: past two variants this is a table, and a table
    /// scrolls sideways. Squeezing the columns until five fit would make
    /// every one of them unreadable to save a gesture.
    ///
    /// Scaled with the type size: at accessibility sizes a fixed 150 points
    /// holds about one word, and the table already knows how to scroll.
    @ScaledMetric(relativeTo: .subheadline) private var columnWidth: CGFloat = 150
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 110

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
                    modePicker
                    switch mode {
                    case .overview:
                        overview
                    case .comparison:
                        table
                        footer
                    }
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
        // Opened again from somewhere else, with a different intent: that
        // intent wins over whatever was switched to last time.
        .onChange(of: initialMode) { chosenMode = nil }
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
        .sousConfirmation(
            "Gruppe auflösen?",
            isPresented: $isConfirmingDissolve,
            message: "Die Rezepte bleiben alle erhalten und stehen danach einzeln in der Liste."
        ) {
            Button("Auflösen", role: .destructive) {
                Task { await library.dissolveVariantGroup(group.id) }
            }
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

    private var modePicker: some View {
        Picker("Ansicht", selection: Binding(get: { mode }, set: { chosenMode = $0 })) {
            ForEach(VariantGroupMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // The full width, unlike the recipe list's own switch: that one sits
        // above a list it filters and reads as a control over it, while this
        // one *is* the page's two states and has nothing to sit beside.
        .frame(maxWidth: .infinity)
    }

    // MARK: - The versions, as recipes

    /// The members as the list draws them anywhere else.
    ///
    /// Deliberately the same `RecipeRow`: someone who came here from a recipe
    /// is asking which other versions exist, and the answer should look like
    /// the rest of the collection rather than like a table about it.
    private var overview: some View {
        VStack(spacing: 0) {
            ForEach(members) { member in
                Button {
                    open(member)
                } label: {
                    RecipeRow(recipe: member)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if member.id != members.last?.id {
                    Divider()
                }
            }
        }
    }

    // MARK: - The comparison

    private var table: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: labelWidth, height: 1)
                    ForEach(members) { member in
                        memberHeader(member)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)

                attributeRow("Portionen") { "\($0.servings)" }
                attributeRow("Zeit") { recipe in
                    recipe.elapsedTimeSeconds.map { "\($0 / 60) Min." } ?? "—"
                }

                if !nutrition.isEmpty {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("Pro Portion")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: labelWidth, alignment: .leading)
                    }
                    // The label's rows, in the label's order — the same
                    // eight the recipe page shows, so a figure read here
                    // and there is the same figure. The energy row carries
                    // the ≈ for an incomplete column; the rows below it
                    // are the same estimate and inherit its flag.
                    nutrientRow("Energie", emphasized: true) { figures in
                        let value = Self.nutrients.string(kilocalories: figures.perPortion.kcal)
                        return figures.coverage.isComplete ? value : "≈ \(value)"
                    }
                    nutrientRow("Fett") { mass($0.perPortion.fatG) }
                    nutrientRow("davon gesättigt", indented: true) { mass($0.perPortion.saturatedFatG) }
                    nutrientRow("Kohlenhydrate") { mass($0.perPortion.carbsG) }
                    nutrientRow("davon Zucker", indented: true) { mass($0.perPortion.sugarG) }
                    nutrientRow("Ballaststoffe") { mass($0.perPortion.fiberG) }
                    nutrientRow("Eiweiß") { mass($0.perPortion.proteinG) }
                    // BLS reports sodium; the label shows salt — the same
                    // conversion the recipe page makes.
                    nutrientRow("Salz") { mass($0.perPortion.sodiumMg * 2.5 / 1000) }
                }

                if !comparison.rows.isEmpty {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("Unterschiede")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: labelWidth, alignment: .leading)
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
                            .foregroundStyle(Color.sousStar)
                            .imageScale(.small)
                    }
                    if member.wantToCook {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(.tint)
                            .imageScale(.small)
                    }
                }
            }
            .frame(width: columnWidth, alignment: .leading)
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
                .frame(width: labelWidth, alignment: .leading)
            ForEach(members) { member in
                Text(value(member))
                    .font(.subheadline)
                    .frame(width: columnWidth, alignment: .leading)
            }
        }
    }

    /// One nutrient across the columns. A member without figures reads as
    /// a dash — same rule as a missing ingredient line below: the absence
    /// is the answer, not a cell nobody filled in.
    private func nutrientRow(
        _ label: String,
        emphasized: Bool = false,
        indented: Bool = false,
        value: @escaping (RecipeNutrition) -> String
    ) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, indented ? 12 : 0)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(members) { member in
                Group {
                    if let figures = nutrition[member.id] {
                        Text(value(figures))
                            .font(emphasized ? .subheadline.weight(.medium) : .subheadline)
                    } else {
                        Text("—")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: columnWidth, alignment: .leading)
            }
        }
    }

    private static let nutrients = NutrientFormatter(locale: .sous)

    private func mass(_ grams: Double) -> String {
        Self.nutrients.string(grams, in: .grams)
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
                .frame(width: labelWidth, alignment: .leading)
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
                .frame(width: columnWidth, alignment: .leading)
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
        var figures: [UUID: RecipeNutrition] = [:]
        for member in members {
            guard let memberNutrition = await nutritionLibrary.nutrition(for: member),
                  memberNutrition.coverage.includedCount > 0
            else { continue }
            figures[member.id] = memberNutrition
        }
        nutrition = figures
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
