import SousKit
import SwiftUI

/// What the planned week needs from the shop.
struct ShoppingListView: View {
    @Environment(ShoppingLibrary.self) private var shopping

    @State private var newItem = ""
    @FocusState private var isAddingItem: Bool

    private let formatter = QuantityFormatter(locale: .sous)

    var body: some View {
        NavigationStack {
            List {
                addRow

                if !shopping.openItems.isEmpty {
                    Section {
                        ForEach(shopping.openItems) { item in
                            row(item)
                        }
                    }
                }

                if !shopping.checkedItems.isEmpty {
                    Section {
                        ForEach(shopping.checkedItems) { item in
                            row(item)
                        }
                    } header: {
                        Text("Erledigt")
                            .font(SousStyle.groupHeading)
                            .textCase(nil)
                    }
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

    @ViewBuilder
    private var addRow: some View {
        HStack {
            Image(systemName: "plus.circle")
                .foregroundStyle(.tint)
            TextField("Etwas hinzufügen, z. B. „2 kg Kartoffeln“", text: $newItem)
                .focused($isAddingItem)
                .onSubmit(add)
            if !newItem.isEmpty {
                Button("Hinzufügen", systemImage: "return", action: add)
                    .labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ShoppingItem) -> some View {
        Group {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    label(for: item)
                        .strikethrough(item.isChecked)
                    if !item.recipeTitles.isEmpty {
                        Text(item.recipeTitles.joined(separator: " · "))
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

    /// The amounts lead, in the accent, because that is what is read while
    /// standing in the shop.
    private func label(for item: ShoppingItem) -> Text {
        let amounts = item.quantities.map { formatter.string(for: $0) }.joined(separator: " + ")
        guard !amounts.isEmpty else { return Text(item.name) }
        return Text(amounts).foregroundStyle(.tint).fontWeight(.medium)
            + Text(" \(item.name)")
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
