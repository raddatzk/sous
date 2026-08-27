import CloudKit
import SousKit
import SwiftUI

/// Inviting someone into the household.
///
/// The whole feature is one button, and that is the point of the arrangement
/// underneath it: the library already lives in a shared CloudKit zone, so
/// there is nothing to prepare, nothing to upload and nobody to wait for. The
/// system's own sheet does the inviting, the permissions, the accepting and
/// the revoking — the app never sees an address and never stores one.
struct HouseholdSharingSection: View {
    let households: CoreDataHouseholds

    @State private var invitation: Invitation?
    @State private var failure: String?
    @State private var isPreparing = false

    var body: some View {
        Section {
            Button {
                Task { await invite() }
            } label: {
                HStack {
                    Label("Haushalt teilen …", systemImage: "person.2")
                    if isPreparing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isPreparing)

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Haushalt")
        } footer: {
            Text("""
            Wer eingeladen wird, sieht dieselben Rezepte, denselben Essensplan \
            und dieselbe Einkaufsliste — und kann alles ändern.
            """)
        }
        #if os(iOS)
        .sheet(item: $invitation) { invitation in
            CloudSharingSheet(share: invitation.share, container: invitation.container)
                .ignoresSafeArea()
        }
        #endif
    }

    private func invite() async {
        isPreparing = true
        failure = nil
        defer { isPreparing = false }

        do {
            let (share, container) = try await households.shareForInviting()
            invitation = Invitation(share: share, container: container)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The two things the sheet needs, as one identifiable value so it can
    /// drive `.sheet(item:)`.
    private struct Invitation: Identifiable {
        let share: CKShare
        let container: CKContainer
        var id: String { share.recordID.recordName }
    }
}

#if os(iOS)
/// The system sharing sheet for a `CKShare`.
///
/// UIKit, because SwiftUI has no equivalent — the iOS 26 SDK mentions neither
/// `CKShare` nor cloud sharing anywhere in its interface.
struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        // What Mela's help describes, and the only reading that makes sense
        // for a household: everyone invited may create, modify and delete.
        // No public link — a household is the people in it, not whoever has
        // the address.
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(share: share) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let share: CKShare

        init(share: CKShare) {
            self.share = share
        }

        /// What the invitation says it is. Without this the sheet offers to
        /// share "Unbenannt".
        func itemTitle(for csc: UICloudSharingController) -> String? {
            share[CKShare.SystemFieldKey.title] as? String ?? "Sous"
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            // The sheet shows its own alert; there is nothing useful to add
            // and nothing for the app to undo — the share either saved or did
            // not, and the library is unaffected either way.
        }
    }
}
#endif

extension EnvironmentValues {
    /// The household store, for the one screen that offers to share it.
    ///
    /// Optional because the Mac reaches `SettingsForm` through the `Settings`
    /// scene, where nothing injects anything — and because sharing is an iOS
    /// surface for now anyway.
    @Entry var households: CoreDataHouseholds?
}
