import SousKit
import SwiftUI

struct RecipeListView: View {
    /// Whether this instance carries the search field.
    ///
    /// The Mac's sidebar does: its field is part of the sidebar and filters
    /// the list under it in place. The phone's does not — searching there is
    /// its own tab and its own view (``RecipeSearchView``), because a search
    /// field in the nav bar shoves the collapsed title into the leading edge,
    /// which is exactly the broken-looking bar this splits apart.
    var showsSearch = true

    @Environment(RecipeLibrary.self) private var library
    @Environment(\.householdSwitcher) private var householdSwitcher
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(RecipeSelection.self) private var selection
    /// Held by the app rather than here, because the menu bar issues the
    /// same commands and cannot see this view's state.
    @Environment(LibraryCommands.self) private var commands

    @State private var selected: RecipeListSelection?
    /// Ties a tapped row to the page it becomes, for the zoom.
    @Namespace private var zoomNamespace
    /// Only the phone offers this: the Mac has the Settings scene behind
    /// Cmd-, and would otherwise reach the same form twice.
    @State private var isShowingSettings = false
    /// The recipe a second version is being made of, while the sheet asking
    /// for its name is up.
    @State private var addingVariantTo: Recipe?
    /// The recipe looking for the one it is a version of, while the picker
    /// is up.
    @State private var joiningVariantsOf: Recipe?

    var body: some View {
        @Bindable var library = library
        @Bindable var commands = commands

        root
            .recipeImporter(isPresented: $commands.isImporting)
            .recipeExporter($commands.export)
            .sheet(item: $commands.panel) { panel in
                switch panel {
                case .catalog: IngredientCatalogView()
                case .categories: CategoryManagerView()
                case .trash: TrashView()
                }
            }
            #if os(iOS)
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            #endif
            .sheet(item: $library.editing) { recipe in
                RecipeEditorView(recipe: recipe) { edited in
                    await library.save(edited)
                    selected = .recipe(edited.id)
                }
            }
            .sheet(item: $addingVariantTo) { recipe in
                AddVariantSheet(recipe: recipe) { variant in
                    // Straight to the new one: it is a copy of what was on
                    // screen a moment ago, and the point is to change it.
                    selected = .recipe(variant.id)
                }
            }
            .sheet(item: $joiningVariantsOf) { recipe in
                VariantJoinPicker(target: .recipe(recipe)) { group in
                    // Onto the comparison, which is both the proof that it
                    // worked and the place the name can be corrected.
                    selection.target = .group(group, mode: .comparison)
                    selected = .group(group.id)
                }
            }
            // A draft the cook walked away from takes its pictures with it.
            .onChange(of: library.editing) { _, editing in
                if editing == nil { Task { await library.discardUnsavedDraft() } }
            }
            .sousErrorAlert(library)
    }

    /// The Mac has one split view for the whole window, so this is only its
    /// first column; the phone brings its own stack and pushes into it.
    @ViewBuilder
    private var root: some View {
        #if os(macOS)
        list
        #else
        NavigationStack {
            list
                // Without this, tapping a row selected it and opened nothing:
                // a list with a selection but no destination goes nowhere.
                .navigationDestination(item: $selected) { target in
                    switch target {
                    case .recipe(let id):
                        if let recipe = library.recipes.first(where: { $0.id == id }) {
                            RecipeDetailView(recipe: recipe)
                                // The page grows out of the row that was
                                // tapped — the row's picture and the hero
                                // are the same photo, and the zoom says so.
                                .navigationTransition(.zoom(sourceID: id, in: zoomNamespace))
                        }
                    case .group(let id):
                        if let group = library.variantGroups[id] {
                            VariantGroupView(group: group, initialMode: mode(forGroup: id))
                        }
                    }
                }
        }
        #endif
    }

    /// One recipe per line, the picture beside the name. What a phone gets,
    /// what a narrow window gets, and what the Mac's first column is.
    @ViewBuilder
    private var listBody: some View {
        @Bindable var library = library

        List(selection: $selected) {
            filterBar
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            // Groups are always open. A disclosure triangle would put the
            // versions of a dish behind a tap and make the list lie about how
            // much is in it; a per-group collapsed state can be added later
            // without touching anything stored.
            ForEach(library.entries) { entry in
                switch entry {
                case .recipe(let recipe):
                    row(for: recipe)
                case .group(let group, let members):
                    VariantGroupRow(
                        group: group,
                        shown: members.count,
                        total: library.variantMemberCounts[group.id] ?? members.count
                    )
                    .tag(RecipeListSelection.group(group.id))
                    .contextMenu { groupActions(for: group) }
                    ForEach(members) { member in
                        row(for: member)
                            // Indented rather than in a `Section`: a section
                            // header on the Mac's sidebar list brings a
                            // collapse behaviour with it that this list does
                            // not want, and both kinds of row have to be
                            // selectable the same way.
                            .padding(.leading, 16)
                    }
                }
            }
        }
        // Without this the selected row is a solid slab of accent across the
        // whole width; a sidebar list draws its selection as a capsule.
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        // With the search field active the navigation title collapses but
        // the room it stood in does not, leaving the filter chips floating
        // half a title below the field. The list keeps its own spacing.
        .contentMargins(.top, 0, for: .scrollContent)
        #endif
    }

    #if os(iOS)
    /// Where the library stops being a list and becomes a shelf.
    ///
    /// Two cards of a readable width with a gap between them — the same
    /// number the other lists cap at, and deliberately so: exactly where a
    /// row stops being able to use the width, the shelf starts using it.
    private static let shelfWidth: CGFloat = 700
    /// The narrowest a card may be before its name stops fitting on two
    /// lines. `adaptive` fills the rest: two columns upright, three or four
    /// on a wide iPad, without anyone counting.
    private static let cardWidth: CGFloat = 260

    /// A run of the library that the shelf draws in one go.
    ///
    /// The list nests a group's versions under its heading by indenting them.
    /// A grid has no indent, so the nesting becomes blocks instead: the loose
    /// recipes flow together, and each group gets a heading of its own with
    /// its versions under it.
    private enum ShelfBlock: Identifiable {
        case recipes([Recipe])
        case group(VariantGroup, members: [Recipe])

        var id: UUID {
            switch self {
            case .recipes(let recipes): recipes.first?.id ?? UUID()
            case .group(let group, _): group.id
            }
        }
    }

    /// Chunks the library's entries into those blocks, keeping their order.
    private var shelfBlocks: [ShelfBlock] {
        var blocks: [ShelfBlock] = []
        var loose: [Recipe] = []
        for entry in library.entries {
            switch entry {
            case .recipe(let recipe):
                loose.append(recipe)
            case .group(let group, let members):
                if !loose.isEmpty {
                    blocks.append(.recipes(loose))
                    loose = []
                }
                blocks.append(.group(group, members: members))
            }
        }
        if !loose.isEmpty { blocks.append(.recipes(loose)) }
        return blocks
    }

    /// The library as a shelf of cards.
    @ViewBuilder
    private var shelf: some View {
        @Bindable var library = library

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                filterBar
                ForEach(shelfBlocks) { block in
                    switch block {
                    case .recipes(let recipes):
                        cardGrid(recipes)
                    case .group(let group, let members):
                        VStack(alignment: .leading, spacing: 12) {
                            groupHeading(group, members: members)
                            cardGrid(members)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        // The page the cards stand on. A `ScrollView` brings the plain
        // background, and white cards on white is no card at all — the list
        // gets this from its grouped style without asking, and the shelf has
        // to ask.
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func cardGrid(_ recipes: [Recipe]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.cardWidth), spacing: 16)],
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(recipes) { recipe in
                card(for: recipe)
            }
        }
    }

    /// One recipe as a card.
    ///
    /// No swipe actions, unlike the row: a card has no edge to swipe from,
    /// and the two judgments a thumb passes while scrolling — favourite,
    /// want to cook — stay on the long-press menu, which already carries
    /// them. The gesture belongs to the shape it was designed for, and that
    /// shape is still what a phone gets.
    private func card(for recipe: Recipe) -> some View {
        Button {
            selected = .recipe(recipe.id)
        } label: {
            RecipeRow(recipe: recipe, layout: .card)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: recipe.id, in: zoomNamespace)
        .contextMenu {
            contextActions(for: recipe)
        } preview: {
            RecipePreviewCard(recipe: recipe)
                .environment(library)
        }
    }

    /// A group's heading above its versions — the same row the list draws,
    /// opening the same comparison.
    private func groupHeading(_ group: VariantGroup, members: [Recipe]) -> some View {
        Button {
            selected = .group(group.id)
        } label: {
            VariantGroupRow(
                group: group,
                shown: members.count,
                total: library.variantMemberCounts[group.id] ?? members.count
            )
        }
        .buttonStyle(.plain)
        .contextMenu { groupActions(for: group) }
    }
    #endif

    /// The library, as whichever shape the width can carry.
    ///
    /// No readable-width cap on this one, unlike the other two lists: where a
    /// row would start wasting the width, this screen has a better answer for
    /// it than a margin.
    @ViewBuilder
    private var entries: some View {
        #if os(macOS)
        listBody
        #else
        GeometryReader { screen in
            if screen.size.width >= Self.shelfWidth {
                shelf
            } else {
                listBody
            }
        }
        #endif
    }

    private var list: some View {
        entries
        // The joined household's name when one is active — the list is its
        // library then, and calling it by the generic name would hide the
        // one fact that matters about what is on screen.
        .navigationTitle(householdSwitcher?.activeName ?? "Rezepte")
        // The switch, as a menu on the title — attached only once there is
        // something to switch to. Deciding that inside the builder is not
        // enough: `.toolbarTitleMenu` draws its chevron beside the title
        // whether or not the menu has anything in it, so anyone who is in no
        // second household got a chevron that opens nothing.
        .modifier(HouseholdTitleMenu(switcher: householdSwitcher))
        .modifier(RecipeSearchField(shows: showsSearch, tokens: tokens))
        .overlay { emptyState }
        .toolbar { listToolbar }
        .task { await library.reload() }
        // The selected row is what the detail column shows. Kept in sync
        // rather than held there, because the list wants an id for its
        // highlight and the column wants the recipe.
        .onChange(of: selected) {
            selection.target = selectedTarget
            // A plain pick from the list means "as written" — a leftover
            // scaling from whatever the meal plan last opened must not
            // follow it here.
            selection.plannedEntryID = nil
        }
        .onChange(of: library.recipes) {
            if selected != nil { selection.target = selectedTarget }
        }
        // Whoever else sets the selection gets this list to follow. On the
        // Mac that is the meal plan and the comparison page, which have
        // their own rows to highlight and no use for this list's id — and
        // it also keeps this list's own selection from going stale, so that
        // a row picked here after a plan-opened recipe switches instead of
        // silently matching what `selected` already held. On the phone it is
        // the one way to change what is pushed from inside the pushed page:
        // "Variante anlegen" opens the new version by naming it here.
        .onChange(of: selection.target) { _, newValue in
            let row: RecipeListSelection? = switch newValue {
            case .recipe(let recipe): .recipe(recipe.id)
            case .group(let group, _): .group(group.id)
            case nil: nil
            }
            if selected != row { selected = row }
        }
    }

    /// One recipe's row, whether it stands on its own or under a group.
    private func row(for recipe: Recipe) -> some View {
        RecipeRow(recipe: recipe)
            #if os(iOS)
            .matchedTransitionSource(id: recipe.id, in: zoomNamespace)
            #endif
            .tag(RecipeListSelection.recipe(recipe.id))
            // The long-press previews the recipe itself, with its actions
            // underneath rather than a bare menu — VISION.md asks for
            // exactly this, and it is what a long-press means on iOS. The
            // Mac keeps the plain menu: a right-click there is a menu, not
            // a peek.
            #if os(iOS)
            .contextMenu {
                contextActions(for: recipe)
            } preview: {
                RecipePreviewCard(recipe: recipe)
                    // The preview is hosted outside the app's view tree and
                    // inherits none of its `.environment` objects — without
                    // this, the image view's environment lookup traps.
                    .environment(library)
            }
            #else
            .contextMenu { contextActions(for: recipe) }
            #endif
            // The two judgments a thumb passes while scrolling the shelf,
            // and the one regret. The full menu stays on the long-press.
            .swipeActions(edge: .leading) {
                Button(
                    recipe.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten",
                    systemImage: recipe.isFavorite ? "star.slash" : "star"
                ) {
                    Task { await library.toggleFavorite(recipe) }
                }
                .tint(Color.sousStar)
                Button(
                    recipe.wantToCook ? "Nicht mehr geplant" : "Will ich kochen",
                    systemImage: recipe.wantToCook ? "bookmark.slash" : "bookmark"
                ) {
                    Task { await library.toggleWantToCook(recipe) }
                }
                .tint(Color.sousAccent)
            }
            .swipeActions(edge: .trailing) {
                Button("Löschen", systemImage: "trash", role: .destructive) {
                    Task { await library.delete(recipe) }
                }
            }
    }

    /// What the group page should open as.
    ///
    /// Whatever the last thing to set the selection asked for, and the
    /// comparison otherwise — which is what a row picked in this list means:
    /// someone looking at the collection who opens a group is weighing its
    /// versions against each other. Read back from the selection rather than
    /// assumed, or the recipe page's smaller question would be overwritten
    /// the moment the list noticed the row.
    private func mode(forGroup id: UUID) -> VariantGroupMode {
        if case .group(let group, let mode) = selection.target, group.id == id { return mode }
        return .comparison
    }

    /// What the selected row stands for, resolved against what the list
    /// currently holds.
    private var selectedTarget: RecipeSelection.Target? {
        switch selected {
        case .recipe(let id):
            library.recipes.first { $0.id == id }.map(RecipeSelection.Target.recipe)
        case .group(let id):
            library.variantGroups[id].map { .group($0, mode: mode(forGroup: id)) }
        case nil:
            nil
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        // An import in progress is about to fill the list; telling the user
        // there is nothing here while it counts up says the opposite.
        if library.recipes.isEmpty, !library.isLoading, library.importProgress == nil {
            if library.searchText.isEmpty, library.filter == .all, library.activeFilters.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Rezepte", systemImage: "book.closed")
                } description: {
                    Text("Lege dein erstes Rezept an.")
                } actions: {
                    Button("Rezept anlegen") { library.startNewRecipe() }
                }
            } else {
                ContentUnavailableView.search
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        @Bindable var library = library
        // Searching is the system's field now; this is the one thing it
        // cannot express — favourites and "will ich kochen" are not filters
        // that stack, they are three views of the same list.
        Picker("Filter", selection: $library.filter) {
            ForEach(RecipeLibrary.Filter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        // macOS shows a segmented picker's label; iOS hides it. Without this
        // the word "Filter" sits in the sidebar beside the three choices.
        .labelsHidden()
        // Three choices stretched across an iPad is a rule with words on it.
        // The cap never bites on a phone, where the screen is narrower.
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// The filters as the search field's tokens.
    ///
    /// Written back as a whole set rather than as add and remove, because
    /// that is what the field hands over: after a backspace it reports the
    /// list it has left, not which token went.
    private var tokens: Binding<[RecipeFilter]> {
        Binding(
            get: { library.activeFilters },
            set: { filters in Task { await library.setFilters(filters) } }
        )
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Neues Rezept", systemImage: "plus") { library.startNewRecipe() }
        }
        // Everything in here is in the Mac's menu bar, which is always on
        // screen — so on the Mac the menu would be empty and is left out
        // entirely. The iPad keeps it: its menu bar waits behind a swipe from
        // the top edge or a keyboard being attached, and a command that only
        // lives there is hidden from anyone using the iPad with their fingers.
        #if os(iOS)
        ToolbarItem(placement: .automatic) {
            Menu("Mehr", systemImage: "ellipsis.circle") {
                Button("Zutaten verwalten", systemImage: "carrot") {
                    commands.panel = .catalog
                }
                Button("Kategorien verwalten", systemImage: "tag") {
                    commands.panel = .categories
                }
                Button("Papierkorb", systemImage: "trash") {
                    commands.panel = .trash
                }
                // No Settings entry on the Mac either — it has the Settings
                // scene behind Cmd-, — but this whole menu is gone there.
                Divider()
                Button("Einstellungen", systemImage: "gearshape") {
                    isShowingSettings = true
                }
                Divider()
                Button("Rezepte importieren", systemImage: "square.and.arrow.down") {
                    commands.isImporting = true
                }
                Button("Alle Rezepte exportieren", systemImage: "square.and.arrow.up") {
                    Task {
                        if let data = await library.exportedLibrary() {
                            commands.export = RecipeExport(
                                data: data,
                                name: "Rezepte",
                                contentType: RecipeExport.library
                            )
                        }
                    }
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func contextActions(for recipe: Recipe) -> some View {
        Button("Bearbeiten", systemImage: "pencil") { library.editing = recipe }
        Button(
            recipe.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten",
            systemImage: recipe.isFavorite ? "star.slash" : "star"
        ) {
            Task { await library.toggleFavorite(recipe) }
        }
        Button(
            recipe.wantToCook ? "Nicht mehr geplant" : "Will ich kochen",
            systemImage: "bookmark"
        ) {
            Task { await library.toggleWantToCook(recipe) }
        }
        Button("Variante anlegen", systemImage: "square.on.square") {
            addingVariantTo = recipe
        }
        if let groupID = recipe.variantGroupID, library.variantGroups[groupID] != nil {
            Button("Aus der Gruppe lösen", systemImage: "square.on.square.slash") {
                Task { await library.removeFromVariantGroup(recipe) }
            }
        } else {
            Button("Mit einem Rezept zusammenfassen", systemImage: "rectangle.stack.badge.plus") {
                joiningVariantsOf = recipe
            }
        }
        Divider()
        Button("Löschen", systemImage: "trash", role: .destructive) {
            Task { await library.delete(recipe) }
        }
    }

    /// A group can be renamed and taken apart, and that is the whole of it —
    /// everything else on the menu above needs a recipe.
    @ViewBuilder
    private func groupActions(for group: VariantGroup) -> some View {
        Button("Vergleichen", systemImage: "square.on.square") {
            selected = .group(group.id)
        }
        Button("Gruppe auflösen", systemImage: "square.on.square.slash") {
            Task { await library.dissolveVariantGroup(group.id) }
        }
    }
}

/// What a row in the library stands for.
///
/// The list holds ids rather than the things themselves, the way it always
/// did: a row wants something small and stable to highlight, and the detail
/// column wants the recipe or group those ids name.
enum RecipeListSelection: Hashable {
    case recipe(Recipe.ID)
    case group(VariantGroup.ID)
}

#if os(iOS)
/// What the long-press lifts off the list: the recipe itself, at a glance —
/// picture, name, what it is, and what goes into it — enough to decide
/// whether to open it, which is the question a peek answers.
private struct RecipePreviewCard: View {
    let recipe: Recipe

    /// Enough lines to know the dish; the page has the rest.
    private static let visibleIngredients = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let imageID = recipe.imageIDs.first {
                RecipeImageView(imageID: imageID)
                    .frame(width: 340, height: 190)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(recipe.title)
                    .font(SousStyle.recipeName)
                if let summary = recipe.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if facts.isEmpty == false {
                    Text(facts)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let ingredients = recipe.ingredients
                if !ingredients.isEmpty {
                    Divider()
                        .padding(.vertical, 2)
                    ForEach(ingredients.prefix(Self.visibleIngredients)) { ingredient in
                        IngredientLineView(ingredient: ingredient)
                            .font(.callout)
                    }
                    if ingredients.count > Self.visibleIngredients {
                        Text("+\(ingredients.count - Self.visibleIngredients) weitere Zutaten")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 340, alignment: .leading)
        .background(Color.sousSurface)
    }

    /// "25 Min. · einfach, Suppe" — the row's chips, said in one line.
    private var facts: String {
        var parts: [String] = []
        if let seconds = recipe.elapsedTimeSeconds {
            parts.append("\(seconds / 60) Min.")
        }
        if !recipe.categories.isEmpty {
            parts.append(recipe.categories.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}
#endif

/// The household switch, hung on the navigation title — and only there when
/// there is a second household to switch to.
///
/// A modifier rather than an `if` around the menu's content, because the
/// chevron is drawn for the modifier's presence rather than for what the
/// builder produces.
private struct HouseholdTitleMenu: ViewModifier {
    let switcher: HouseholdSwitcher?

    func body(content: Content) -> some View {
        if let switcher, switcher.hasJoined {
            content.toolbarTitleMenu { menu(switcher) }
        } else {
            content
        }
    }

    /// The households to choose from. The own one is `nil` in the
    /// switcher's terms, whatever its row's id says.
    @ViewBuilder
    private func menu(_ switcher: HouseholdSwitcher) -> some View {
        ForEach(switcher.choices) { choice in
            Button {
                Task { await switcher.switchTo(choice.isOwn ? nil : choice.id) }
            } label: {
                let isActive = choice.isOwn
                    ? switcher.activeID == nil
                    : switcher.activeID == choice.id
                if isActive {
                    Label(choice.name, systemImage: "checkmark")
                } else {
                    Text(choice.name)
                }
            }
        }
    }
}

/// The search field, attached only where searching is this instance's job —
/// which since the phone's search became a tab of its own means the Mac's
/// sidebar, where the field filters the list under it in place.
///
/// A `ViewModifier` rather than an `if` around the chain so the list itself
/// keeps one identity per instance; `shows` never changes at run time.
private struct RecipeSearchField: ViewModifier {
    let shows: Bool
    let tokens: Binding<[RecipeFilter]>

    @Environment(RecipeLibrary.self) private var library
    @Environment(\.householdSwitcher) private var householdSwitcher
    @Environment(IngredientCatalogLibrary.self) private var catalog

    func body(content: Content) -> some View {
        if shows {
            @Bindable var library = library
            // `.automatic`, which here resolves to the sidebar's own
            // field. The old `.toolbar` placement was an attempt to reach
            // the phone's bottom edge from inside a regular tab — what it
            // actually did was cram a magnifier circle into the nav bar and
            // shove the collapsed title out of center. The phone reaches
            // that edge the way iOS 26 means it to: `Tab(role: .search)`.
            content
                .searchable(
                    text: $library.searchText,
                    tokens: tokens,
                    prompt: "Titel, Zutat, Kategorie"
                ) { filter in
                    Label(filter.title, systemImage: filter.symbolName)
                }
                .searchSuggestions { suggestions }
        } else {
            content
        }
    }

    /// What the typed text could be turned into, offered while typing.
    ///
    /// Says why something matched when its own name does not contain what
    /// was typed — otherwise "Gurke" appears for "sal" with no way to tell
    /// why.
    @ViewBuilder
    private var suggestions: some View {
        ForEach(library.filterSuggestions(catalog: catalog.catalog)) { filter in
            Button {
                Task { await library.apply(filter) }
            } label: {
                HStack(spacing: 6) {
                    Label(filter.title, systemImage: filter.symbolName)
                    if let matched = filter.matchedAs {
                        Text(matched)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
