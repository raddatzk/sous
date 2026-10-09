import SousKit
import SwiftUI

/// What a cook sees when the catalog names another address for the provider
/// they saved a key with: both addresses, where the provider says so, and the
/// request to look for themselves before the key goes anywhere new.
///
/// Until they confirm, nothing changes: the key keeps going to the address it
/// was saved with. Declining leaves it there, and the notice stays.
struct AddressMoveSheet: View {
    let move: AddressMove
    /// Whose key it is: for a household's, one member's yes changes it for all.
    let isHousehold: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var checked = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Bisher") { Text(move.fromHost).textSelection(.enabled) }
                    LabeledContent("Neu") { Text(move.toHost).textSelection(.enabled).bold() }
                } header: {
                    Text("Adresse von \(move.providerName)")
                } footer: {
                    Text("Dein Schlüssel geht an die Adresse, mit der du ihn gespeichert hast. Erst wenn du die neue bestätigst, schickt Sous ihn dorthin.\(isHousehold ? " Beim Schlüssel des Haushalts gilt das dann für alle im Haushalt." : "")")
                }

                Section {
                    if let reason = move.reason { Text(reason) }
                    if let source = move.source {
                        Link(destination: source) {
                            Label("Ankündigung des Anbieters", systemImage: "arrow.up.forward.app")
                        }
                    }
                    Link(destination: move.docs) {
                        Label("Dokumentation des Anbieters", systemImage: "arrow.up.forward.app")
                    }
                } header: {
                    Text("Selbst nachsehen")
                } footer: {
                    Text(move.source == nil
                        ? "Die Liste nennt dazu keine Ankündigung. Sieh in der Dokumentation des Anbieters nach, ob \(move.toHost) seine Adresse ist."
                        : "Vergleiche die Adresse dort mit der neuen, bevor du bestätigst.")
                }

                Section {
                    Toggle("Ich habe die neue Adresse selbst geprüft", isOn: $checked)
                    Button("Neue Adresse übernehmen") {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(!checked)
                    Button("Bei der bisherigen bleiben", role: .cancel) { dismiss() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Adresse prüfen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .interactiveDismissDisabled(checked)
        .sousSheetSizing(.form)
    }
}

/// The reminder in the places that use a connection: it says what changed and
/// opens the decision. Shown for as long as the move is open.
struct AddressMoveNotice: View {
    let move: AddressMove
    let isHousehold: Bool
    let onConfirm: () -> Void

    @State private var isShowing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Die Adresse von \(move.providerName) hat sich geändert.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Dein Schlüssel geht weiter an \(move.fromHost), bis du \(move.toHost) bestätigst.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Prüfen …") { isShowing = true }
        }
        .sheet(isPresented: $isShowing) {
            AddressMoveSheet(move: move, isHousehold: isHousehold, onConfirm: onConfirm)
        }
    }
}
