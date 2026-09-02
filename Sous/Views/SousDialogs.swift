import SousKit
import SwiftUI

/// The app's two dialogs, written once.
///
/// An error and a confirmation are the only things the app ever interrupts
/// the reader with, and each used to be built by hand where it was needed —
/// four copies of the error alert with two different titles, and destructive
/// questions asked as an alert in one place and a confirmation dialog in
/// three others. The dialog drops its cancel button on iOS 26, which would
/// leave "take it off the hob" as the only thing on screen to press; so the
/// question is an alert everywhere, with the cancel button always there and
/// always last. A choice between two things to do — the trolley's second tap
/// on the recipe page — is a menu rather than a question and stays a
/// confirmation dialog.
extension View {
    /// Shows what `source` last failed at, and clears it once read.
    ///
    /// Attached by the screen that owns the library's writes — the list for
    /// the shopping library, the plan for the meal plan — so that every
    /// library's failures have one place to appear. Attaching it twice for
    /// one library is harmless but pointless: the first screen up shows it.
    @MainActor
    func sousErrorAlert(_ source: some ErrorReporting) -> some View {
        sousErrorAlert(Binding(
            get: { source.errorMessage },
            set: { source.errorMessage = $0 }
        ))
    }

    /// The same alert for an error a view holds itself.
    @MainActor
    func sousErrorAlert(_ message: Binding<String?>) -> some View {
        alert("Fehler", isPresented: Binding(presence: message)) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }

    /// Asks before something that cannot be taken back.
    ///
    /// `actions` holds the one or two buttons that go ahead — destructive
    /// where they destroy — and the cancel button is added here, so no
    /// question can be asked without a way out of it. `cancel` names that
    /// way out where "Abbrechen" would be wrong: in cook mode the alternative
    /// to taking a dish off the hob is to keep cooking, not to cancel.
    @MainActor
    func sousConfirmation<Actions: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        cancel: String = "Abbrechen",
        message: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        alert(title, isPresented: isPresented) {
            actions()
            Button(cancel, role: .cancel) {}
        } message: {
            if let message {
                Text(message)
            }
        }
    }
}

extension Binding where Value == Bool {
    /// Whether an optional holds something, as the flag a sheet or an alert
    /// wants — and turning the flag off clears the optional, which is how a
    /// dismissed dialog forgets what it was about.
    init<Wrapped>(presence source: Binding<Wrapped?>) {
        self.init(
            get: { source.wrappedValue != nil },
            set: { if !$0 { source.wrappedValue = nil } }
        )
    }
}
