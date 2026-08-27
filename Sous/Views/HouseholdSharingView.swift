import CloudKit
import SousKit
import SwiftUI

/// Inviting someone into the household.
///
/// The whole feature is one `ShareLink`, and that is the point of the
/// arrangement underneath it: the system sheet does the inviting, the
/// permissions, the accepting and the revoking — the app never sees an
/// address and never stores one.
///
/// A `ShareLink` over `CKShareTransferRepresentation` rather than
/// `UICloudSharingController` in a sheet, and not for taste: the wrapped
/// controller dismisses itself the moment it appears when presented from
/// SwiftUI — taking the settings sheet with it — which is exactly the
/// "tapped the button, landed back in the recipe list" a person sees. The
/// transfer representation is also honest about time: the share is prepared
/// when a destination is chosen, so there is no window in which the sheet
/// shows a share the server has not heard of yet.
struct HouseholdSharingSection: View {
    let households: CoreDataHouseholds

    var body: some View {
        Section {
            HouseholdShareLink(households: households)
        } header: {
            Text("Haushalt")
        } footer: {
            Text("""
            Wer eingeladen wird, sieht dieselben Rezepte, denselben Essensplan \
            und dieselbe Einkaufsliste — und kann alles ändern.
            """)
        }
    }
}

/// The invitation itself: one button, and what to say when there is nothing
/// behind it.
///
/// Its own view because the welcome offers the same thing on its last page,
/// and a second `ShareLink` written out there would be a second set of
/// sharing options to keep in step with this one.
///
/// It brings no styling of its own — in the settings it is a row in a form,
/// in the welcome a prominent button, and that is the caller's business.
struct HouseholdShareLink: View {
    let households: CoreDataHouseholds

    var body: some View {
        if SousPersistentContainer.isConfiguredForCloudKit {
            ShareLink(
                item: HouseholdInvitation(households: households),
                preview: SharePreview(CoreDataHouseholds.defaultName)
            ) {
                Label("Haushalt teilen …", systemImage: "person.2")
            }
        } else {
            // The one place the quiet local fallback becomes visible:
            // a person about to invite somebody deserves to know why
            // they cannot, and "the button does nothing" is not it.
            Label("Haushalt teilen …", systemImage: "person.2")
                .foregroundStyle(.secondary)
            Text("Sous kann gerade nicht auf iCloud zugreifen. Melde dich in den Systemeinstellungen bei iCloud an.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The household, as something the share sheet can send.
///
/// `preparationHandler` runs when the person picks a destination, and that is
/// the moment the library moves into its shared zone — the once-per-household
/// cost the sharing concept describes.
struct HouseholdInvitation: Transferable {
    let households: CoreDataHouseholds

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { invitation in
            .prepareShare(
                container: CKContainer(
                    identifier: SousPersistentContainer.cloudKitContainerIdentifier
                ),
                // What Mela's help describes, and the only reading that makes
                // sense for a kitchen: everyone invited may create, modify
                // and delete, and there is no public link — a household is
                // the people in it, not whoever has the address.
                allowedSharingOptions: CKAllowedSharingOptions(
                    allowedParticipantPermissionOptions: .readWrite,
                    allowedParticipantAccessOptions: .specifiedRecipientsOnly
                )
            ) {
                try await invitation.households.shareForInviting().share
            }
        }
    }
}

extension EnvironmentValues {
    /// The household store, for the one screen that offers to share it.
    ///
    /// Optional because the Mac reaches `SettingsForm` through the `Settings`
    /// scene, where nothing injects anything — and because sharing is an iOS
    /// surface for now anyway.
    @Entry var households: CoreDataHouseholds?
}
