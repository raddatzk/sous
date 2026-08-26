import SousKit
import SwiftUI

/// The shopping list, readable two ways: as one line per ingredient for the
/// shop, or split by dish — where each recipe keeps its portion dial.
struct ShoppingListView: View {
    @Environment(ShoppingLibrary.self) private var shopping

    @State private var grouping: Grouping = .aisle
    @State private var newItem = ""
    /// The pantry is a check-through list, not errands — it starts folded.
    @State private var pantryExpanded = false

    private let formatter = QuantityFormatter(locale: .sous)

    private enum Grouping: String, CaseIterable {
        case aisle
        case recipe

        var title: String {
            switch self {
            case .aisle: "Nach Abteilung"
            case .recipe: "Nach Rezept"
            }
        }
    }

    var body: some View {
        // The Mac has one split view for the whole window, so this is only
        // its first column; the phone brings its own stack.
        #if os(macOS)
        list
        #else
        NavigationStack { list }
        #endif
    }

    @ViewBuilder
    private var list: some View {
        List {
            addRow

            if !shopping.items.isEmpty, shopping.hasRecipeDemands {
                Picker("Ansicht", selection: $grouping) {
                    ForEach(Grouping.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            switch grouping {
            case .aisle: byAisle
            case .recipe: byRecipe
            }
        }
        .navigationTitle("Einkaufsliste")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !shopping.checkedItems.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Erledigte entfernen", systemImage: "trash") {
                        Task { await shopping.clearChecked() }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .overlay { emptyState }
        .task { await shopping.reload() }
        .refreshable { await shopping.reload() }
    }

    /// Grouped for the walk through the store: unassigned lines first so
    /// they surface before the shop, then the aisles, then the folded
    /// pantry. What is already in the basket drops to the bottom.
    @ViewBuilder
    private var byAisle: some View {
        ForEach(openSections, id: \.section) { group in
            Section {
                place(group.items)
            } header: {
                sectionHeader(group.section.title)
            }
        }

        if !checkedErrands.isEmpty {
            Section {
                place(checkedErrands)
            } header: {
                sectionHeader("Erledigt")
            }
        }

        pantrySection
    }

    /// A stretch of the list as the places it occupies: an ingredient and
    /// its varieties are one place, with the varieties readable underneath.
    @ViewBuilder
    private func place(_ items: [ShoppingItem], showingSource: Bool = true) -> some View {
        ForEach(shopping.grouped(items)) { group in
            if group.isGrouped {
                variantGroup(group, showingSource: showingSource)
            } else if let item = group.items.first {
                row(item, showingSource: showingSource)
            }
        }
    }

    /// The concept's grouped entry: one heading with the total, and a
    /// sub-line per variety that keeps the word the recipe wrote.
    ///
    /// The heading is not checkable — the sub-lines are. Ticking a group off
    /// as a whole would be the lossy single line all over again: what went
    /// into the basket was 200 g of cocktail tomatoes, not a share of 700 g
    /// of tomatoes.
    @ViewBuilder
    private func variantGroup(_ group: ShoppingGroup, showingSource: Bool) -> some View {
        // Sibling rows rather than one row holding a stack: the sub-lines are
        // the checkable things here, and a row nested inside another row gets
        // neither its swipe actions nor its own selection.
        groupHeadline(group)
        ForEach(group.items) { item in
            row(item, showingSource: showingSource, isSubline: true)
        }
    }

    private func groupHeadline(_ group: ShoppingGroup) -> some View {
        let amounts = group.quantities.map { formatter.string(for: $0) }.joined(separator: " + ")
        let amount = Text(amounts).foregroundStyle(.tint).fontWeight(.medium)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            amounts.isEmpty ? Text(group.name) : Text("\(amount) \(group.name)")
            Spacer(minLength: 0)
        }
        .opacity(group.isChecked ? 0.5 : 1)
    }

    /// The open items of every section but the pantry, which keeps its own
    /// checked rows and comes last.
    private var openSections: [(section: ShoppingSection, items: [ShoppingItem])] {
        shopping.bySection.compactMap { group in
            guard group.section != .pantry else { return nil }
            let open = group.items.filter { !$0.isChecked }
            return open.isEmpty ? nil : (group.section, open)
        }
    }

    private var checkedErrands: [ShoppingItem] {
        shopping.checkedItems.filter { !shopping.isPantry($0) }
    }

    /// Pantry staples as a check-through list: open and checked stay in
    /// place here rather than wandering to "Erledigt".
    @ViewBuilder
    private var pantrySection: some View {
        let pantry = shopping.bySection.first { $0.section == .pantry }?.items ?? []
        if !pantry.isEmpty {
            Section {
                if pantryExpanded {
                    place(pantry)
                }
            } header: {
                Button {
                    withAnimation { pantryExpanded.toggle() }
                } label: {
                    HStack {
                        sectionHeader("Vorräte")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(pantryExpanded ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var byRecipe: some View {
        ForEach(shopping.byRecipe) { group in
            Section {
                ForEach(group.items) { item in
                    row(item, showingSource: false, note: subrecipeNote(for: item, in: group))
                }
            } header: {
                recipeHeader(for: group)
            }
        }
    }

    /// A recipe's heading — with its portion dial, where the entry knows
    /// the scale it was captured at.
    @ViewBuilder
    private func recipeHeader(for group: ShoppingRecipeGroup) -> some View {
        if let planEntry = group.planEntry {
            HStack {
                sectionHeader(group.title)
                Spacer()
                Stepper {
                    Text("\(planEntry.servingsCurrent) Portionen")
                        .font(.caption)
                        .monospacedDigit()
                } onIncrement: {
                    Task { await shopping.setServings(planEntry.servingsCurrent + 1, for: planEntry) }
                } onDecrement: {
                    Task { await shopping.setServings(planEntry.servingsCurrent - 1, for: planEntry) }
                }
                .fixedSize()
            }
            .contextMenu {
                Button("Rezept von der Liste nehmen", systemImage: "trash", role: .destructive) {
                    Task { await shopping.remove(planEntry: planEntry) }
                }
            }
        } else {
            sectionHeader(group.title)
        }
    }

    @ViewBuilder
    private var addRow: some View {
        HStack {
            Image(systemName: "plus.circle")
                .foregroundStyle(.tint)
            TextField("Etwas hinzufügen, z. B. „2 kg Kartoffeln“", text: $newItem)
                .onSubmit(add)
            if !newItem.isEmpty {
                Button("Hinzufügen", systemImage: "return", action: add)
                    .labelStyle(.iconOnly)
            }
        }
    }

    /// A resolved subrecipe keeps its title as the origin its demands read
    /// as — under the parent's section, the flour still says it is naan's.
    private func subrecipeNote(for item: ShoppingItem, in group: ShoppingRecipeGroup) -> String? {
        let foreign = item.originTitles.filter { $0 != group.title }
        guard !foreign.isEmpty else { return nil }
        return "aus \(foreign.joined(separator: " · "))"
    }

    @ViewBuilder
    private func row(
        _ item: ShoppingItem, showingSource: Bool, note: String? = nil, isSubline: Bool = false
    ) -> some View {
        // A button rather than a tap gesture: the pointer changes over it,
        // the keyboard reaches it, and the Mac gets the click it expects.
        Button {
            Task { await shopping.toggle(item) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    label(for: item, isSubline: isSubline)
                        .strikethrough(item.isChecked)
                    if let annotation = annotation(for: item) {
                        Text(annotation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if showingSource, let origin = originText(for: item) {
                        Text(origin)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .opacity(item.isChecked ? 0.5 : 1)
            .padding(.leading, isSubline ? 16 : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions { actions(for: item) }
        // The same actions again, because a swipe needs a trackpad to exist
        // at all and gives no sign that it is there.
        .contextMenu { actions(for: item) }
    }

    @ViewBuilder
    private func actions(for item: ShoppingItem) -> some View {
        if !item.key.isEmpty {
            if shopping.isPantry(item) {
                Button("Kein Vorrat mehr", systemImage: "cabinet") {
                    Task { await shopping.setPantry(false, name: item.name) }
                }
            } else {
                Button("Als Vorrat merken", systemImage: "cabinet") {
                    Task { await shopping.setPantry(true, name: item.name) }
                }
            }
        }
        Button("Entfernen", systemImage: "trash", role: .destructive) {
            Task { await shopping.remove(item) }
        }
    }

    /// What changed under the cook's hands since the check-off: demand that
    /// arrived late, and demand that lapsed.
    private func annotation(for item: ShoppingItem) -> String? {
        var parts: [String] = []
        if item.isLateAddition {
            parts.append("Nachträglich")
        }
        let lapsed = item.lapsedQuantities.map { formatter.string(for: $0) }.joined(separator: " + ")
        if !lapsed.isEmpty {
            parts.append("− \(lapsed) entfallen")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Two names at most — a staple wanted by five dishes would otherwise
    /// bury the line it belongs to.
    private func originText(for item: ShoppingItem) -> String? {
        let titles = item.originTitles
        guard !titles.isEmpty else { return nil }
        guard titles.count > 2 else { return titles.joined(separator: " · ") }
        return "\(titles[0]) · \(titles[1]) +\(titles.count - 2)"
    }

    /// The amounts lead, in the accent, because that is what is read while
    /// standing in the shop.
    private func label(for item: ShoppingItem, isSubline: Bool = false) -> Text {
        let amounts = item.quantities.map { formatter.string(for: $0) }.joined(separator: " + ")
        // Under a grouped heading the row says what makes it different: the
        // word the recipe wrote. Capture replaces that word with the
        // catalog's for the heading, and the demand is where it survived.
        let name = isSubline ? (item.writtenNames.first ?? item.name) : item.name
        guard !amounts.isEmpty else { return Text(name) }
        let amount = Text(amounts).foregroundStyle(.tint).fontWeight(.medium)
        return Text("\(amount) \(name)")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(SousStyle.groupHeading)
            .textCase(nil)
    }

    @ViewBuilder
    private var emptyState: some View {
        if shopping.items.isEmpty {
            ContentUnavailableView {
                Label("Nichts einzukaufen", systemImage: "cart")
            } description: {
                Text("Setze ein Rezept oder eine geplante Woche auf die Liste, oder tippe oben etwas ein.")
            }
        }
    }

    private func add() {
        let line = newItem
        newItem = ""
        Task { await shopping.addItem(line) }
    }
}
