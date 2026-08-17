import SousKit
import SwiftUI

/// The shopping list, readable two ways: as one line per ingredient for the
/// shop, or split by dish to check whether everything for a meal is there.
struct ShoppingListView: View {
    @Environment(ShoppingLibrary.self) private var shopping

    @State private var grouping: Grouping = .ingredient
    @State private var newItem = ""

    private let formatter = QuantityFormatter(locale: .sous)

    private enum Grouping: String, CaseIterable {
        case ingredient
        case recipe

        var title: String {
            switch self {
            case .ingredient: "Nach Zutat"
            case .recipe: "Nach Rezept"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                addRow

                if !shopping.items.isEmpty, hasRecipeSources {
                    Picker("Ansicht", selection: $grouping) {
                        ForEach(Grouping.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                switch grouping {
                case .ingredient: byIngredient
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
    }

    private var hasRecipeSources: Bool {
        shopping.items.contains { !$0.sources.isEmpty }
    }

    @ViewBuilder
    private var byIngredient: some View {
        if !shopping.openItems.isEmpty {
            Section {
                ForEach(shopping.openItems) { item in
                    row(item, showingSource: true)
                }
            }
        }
        if !shopping.checkedItems.isEmpty {
            Section {
                ForEach(shopping.checkedItems) { item in
                    row(item, showingSource: true)
                }
            } header: {
                sectionHeader("Erledigt")
            }
        }
    }

    @ViewBuilder
    private var byRecipe: some View {
        ForEach(shopping.byRecipe, id: \.recipe) { group in
            Section {
                ForEach(group.items) { item in
                    row(item, showingSource: false)
                }
            } header: {
                sectionHeader(group.recipe)
            }
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

    @ViewBuilder
    private func row(_ item: ShoppingItem, showingSource: Bool) -> some View {
        Group {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    label(for: item)
                        .strikethrough(item.isChecked)
                    if showingSource, let origin = originText(for: item) {
                        Text(origin)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .opacity(item.isChecked ? 0.5 : 1)
        }
        .contentShape(.rect)
        .onTapGesture { Task { await shopping.toggle(item) } }
        .swipeActions {
            Button("Entfernen", systemImage: "trash", role: .destructive) {
                Task { await shopping.remove(item) }
            }
        }
    }

    /// Two names at most — a staple wanted by five dishes would otherwise
    /// bury the line it belongs to.
    private func originText(for item: ShoppingItem) -> String? {
        let titles = item.recipeTitles
        guard !titles.isEmpty else { return nil }
        guard titles.count > 2 else { return titles.joined(separator: " · ") }
        return "\(titles[0]) · \(titles[1]) +\(titles.count - 2)"
    }

    /// The amounts lead, in the accent, because that is what is read while
    /// standing in the shop.
    private func label(for item: ShoppingItem) -> Text {
        let amounts = item.quantities.map { formatter.string(for: $0) }.joined(separator: " + ")
        guard !amounts.isEmpty else { return Text(item.name) }
        return Text(amounts).foregroundStyle(.tint).fontWeight(.medium)
            + Text(" \(item.name)")
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
