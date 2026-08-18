import SousKit
import SwiftUI

/// The categories in use, and what they are called.
///
/// Categories are not defined anywhere; they exist because recipes use them.
/// So managing them means renaming across every recipe at once — and renaming
/// onto an existing name is how two spellings become one.
struct CategoryManagerView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var counts: [(name: String, count: Int)] = []
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(counts, id: \.name) { entry in
                    // A button rather than a tap gesture: the pointer changes
                    // over it, the keyboard reaches it, and the Mac gets the
                    // click it expects.
                    Button {
                        newName = entry.name
                        renaming = entry.name
                    } label: {
                        HStack {
                            Label(entry.name, systemImage: "tag")
                            Spacer()
                            Text("\(entry.count)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .swipeActions { deleteAction(entry.name) }
                    // The same action again, because a swipe needs a trackpad
                    // to exist at all and gives no sign that it is there.
                    .contextMenu { deleteAction(entry.name) }
                }
            }
            .navigationTitle("Kategorien")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .overlay {
                if counts.isEmpty {
                    ContentUnavailableView(
                        "Keine Kategorien",
                        systemImage: "tag",
                        description: Text("Kategorien entstehen, sobald du sie in einem Rezept vergibst.")
                    )
                }
            }
        }
        .task { await reload() }
        .alert("Umbenennen", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("Umbenennen") { rename() }
        } message: {
            if let renaming, counts.contains(where: {
                $0.name.lowercased() == newName.lowercased() && $0.name.lowercased() != renaming.lowercased()
            }) {
                Text("„\(newName)“ gibt es bereits — die beiden werden zusammengeführt.")
            } else {
                Text("Der neue Name gilt für alle Rezepte mit dieser Kategorie.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #elseif os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func rename() {
        guard let old = renaming else { return }
        renaming = nil
        Task {
            await library.renameCategory(old, to: newName)
            await reload()
        }
    }

    @ViewBuilder
    private func deleteAction(_ name: String) -> some View {
        Button("Entfernen", systemImage: "trash", role: .destructive) {
            Task {
                await library.deleteCategory(name)
                await reload()
            }
        }
    }

    private func reload() async {
        counts = await library.categoryCounts()
    }
}
