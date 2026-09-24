import SousKit
import SwiftUI

/// The settings' way into the household that is showing: its name, and
/// whether anybody else is in it.
///
/// One row rather than the controls themselves, because a household has
/// grown more than a section's worth — a name, the people in it, and the
/// ways to end it. On iOS it pushes the page inside the settings; the Mac's
/// settings window has no navigation of its own, so there it is a sheet.
struct HouseholdSettingsRow: View {
    @Environment(\.households) private var households
    @Environment(\.householdSwitcher) private var switcher

    @State private var standing: HouseholdStanding?
    #if os(macOS)
    @State private var isShowingPage = false
    #endif

    var body: some View {
        if let households, let id = switcher?.activeID {
            Section {
                #if os(macOS)
                Button { isShowingPage = true } label: { label }
                    .sheet(isPresented: $isShowingPage, onDismiss: { Task { await load(id, from: households) } }) {
                        NavigationStack {
                            HouseholdPage()
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button(role: .close) { isShowingPage = false }
                                    }
                                }
                        }
                        .sousSheetSizing(.page)
                    }
                #else
                NavigationLink { HouseholdPage() } label: { label }
                #endif
            } header: {
                Text("Haushalt")
            } footer: {
                Text("Name, Einladungen, Mitglieder — und Leeren oder Löschen, für den Haushalt, der gerade zu sehen ist.")
            }
            .task(id: id) { await load(id, from: households) }
            // Back from the page, where the name or the members may have
            // changed.
            .onAppear { Task { await load(id, from: households) } }
        }
    }

    private var label: some View {
        LabeledContent {
            Text(summary)
        } label: {
            Label(standing?.name ?? "Haushalt", systemImage: "person.2")
        }
    }

    private var summary: String {
        guard let standing else { return "" }
        guard standing.isOwn else { return "Beigetreten" }
        switch standing.otherParticipants {
        case 0: return standing.isShared ? "Geteilt" : "Nicht geteilt"
        case 1: return "Mit 1 Person geteilt"
        case let count: return "Mit \(count) Personen geteilt"
        }
    }

    private func load(_ id: UUID, from households: CoreDataHouseholds) async {
        standing = await households.standing(of: id)
    }
}

/// Everything about the household that is showing, on one page: its name,
/// inviting people into it, who is in it, and — at the bottom — emptying,
/// ending the sharing, deleting or leaving it.
///
/// No sharing switch: "off" would mean removing everybody, which a switch
/// makes look undoable, and "on" with nobody in it means nothing. Whether a
/// household is shared follows from whether anybody was invited, and the
/// name it needs for that is asked for right above the invitation.
///
/// Inviting stays with the system's share sheet, so the app never sees an
/// address. Who is in it is read off the share as this device last fetched
/// it; pulling down (on iOS) asks again.
struct HouseholdPage: View {
    @Environment(\.households) private var households
    @Environment(\.householdSwitcher) private var switcher
    @Environment(\.calendarMirror) private var calendarMirror

    @State private var standing: HouseholdStanding?
    @State private var members: [HouseholdMember] = []
    /// The member whose removal is being confirmed.
    @State private var removing: HouseholdMember?
    @State private var failure: String?
    /// Recipes erased so far while emptying — over the whole page, see
    /// `HouseholdDataSection`.
    @State private var progress: (done: Int, total: Int)?

    var body: some View {
        Form {
            if let households, let id = switcher?.activeID, let standing {
                nameSection(households: households, id: id, standing: standing)
                if !members.isEmpty {
                    membersSection(standing: standing)
                }
                if let calendarMirror {
                    HouseholdCalendarSection(mirror: calendarMirror, householdID: id, name: standing.name)
                }
                HouseholdDataSection(progress: $progress) { await reload() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(standing?.name ?? "Haushalt")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: switcher?.activeID) { await reload() }
        .refreshable { await reload() }
        .overlay {
            if let progress {
                EraseProgressOverlay(done: progress.done, total: progress.total)
            }
        }
        .confirmationDialog(
            "\(removing.map(Self.title(of:)) ?? "") aus dem Haushalt entfernen?",
            isPresented: Binding(presence: $removing),
            titleVisibility: .visible,
            presenting: removing
        ) { member in
            Button("Entfernen", role: .destructive) {
                Task { await remove(member) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Der Haushalt verschwindet von ihren Geräten. Was sie hineingeschrieben haben, bleibt.")
        }
        .alert(
            "Das hat nicht geklappt",
            isPresented: Binding(presence: $failure),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure)
        }
    }

    @ViewBuilder
    private func nameSection(households: CoreDataHouseholds, id: UUID, standing: HouseholdStanding) -> some View {
        if standing.isOwn {
            Section {
                HouseholdShareLink(
                    households: households,
                    householdID: id,
                    label: members.count > 1 ? "Weitere einladen …" : "Jemanden einladen …",
                    onRenamed: { await reload() }
                )
            } header: {
                Text("Name und Einladung")
            } footer: {
                Text("""
                Wer eingeladen wird, sieht dieselben Rezepte, denselben \
                Essensplan und dieselbe Einkaufsliste — und kann alles ändern. \
                Am Namen erkennen alle, die du einlädst, den Haushalt neben \
                ihren eigenen.
                """)
            }
        } else {
            Section {
                LabeledContent("Name", value: standing.name)
            } footer: {
                Text("Den Namen vergibt, wem der Haushalt gehört.")
            }
        }
    }

    private func membersSection(standing: HouseholdStanding) -> some View {
        Section("Mitglieder") {
            ForEach(members) { member in
                let removable = standing.isOwn && !member.isOwner
                MemberRow(member: member)
                    .swipeActions {
                        if removable {
                            Button("Entfernen", role: .destructive) { removing = member }
                        }
                    }
                    .contextMenu {
                        if removable {
                            Button("Entfernen", systemImage: "person.badge.minus", role: .destructive) {
                                removing = member
                            }
                        }
                    }
            }
        }
    }

    private func reload() async {
        guard let households, let id = switcher?.activeID else { return }
        standing = await households.standing(of: id)
        members = await households.members(of: id)
    }

    private func remove(_ member: HouseholdMember) async {
        guard let households, let id = switcher?.activeID else { return }
        do {
            try await households.remove(member: member.id, from: id)
            await reload()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Who somebody is, as far as CloudKit lets on: their name once they
    /// have accepted, the address they were invited at before that.
    static func title(of member: HouseholdMember) -> String {
        if member.isCurrentUser { return "Du" }
        return member.name ?? member.contact ?? "Eingeladene Person"
    }
}

/// One person in the household, and where they stand.
private struct MemberRow: View {
    let member: HouseholdMember

    var body: some View {
        LabeledContent {
            Text(role)
        } label: {
            Label(HouseholdPage.title(of: member), systemImage: member.isOwner ? "crown" : "person")
        }
    }

    private var role: String {
        if member.isOwner { return "Besitzer" }
        return member.hasJoined ? "Dabei" : "Eingeladen"
    }
}

/// The household's plan in the Apple calendar — a projection the cook opts
/// into, one calendar per household.
private struct HouseholdCalendarSection: View {
    let mirror: CalendarMirror
    let householdID: UUID
    let name: String

    @State private var isOn = false
    @State private var wasDeclined = false

    var body: some View {
        Section {
            Toggle("Essensplan im Kalender", systemImage: "calendar", isOn: $isOn)
                .onChange(of: isOn) { _, wanted in
                    Task { await apply(wanted) }
                }
            if wasDeclined {
                Text("""
                Sous darf nicht auf den Kalender zugreifen. Erlaube den \
                Zugriff in den Systemeinstellungen unter Datenschutz.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Kalender")
        } footer: {
            Text("""
            Die geplanten Rezepte dieses Haushalts erscheinen als Termine in \
            einem eigenen Kalender „Sous – \(name)“ — den du wie jeden \
            Kalender teilen kannst, auch mit Leuten ohne die App. Der Plan \
            bleibt die Wahrheit: Änderungen am Termin wandern nicht zurück.
            """)
        }
        .task(id: householdID) { isOn = mirror.isEnabled(for: householdID) }
    }

    private func apply(_ wanted: Bool) async {
        guard wanted != mirror.isEnabled(for: householdID) else { return }
        if wanted {
            let granted = await mirror.enable(for: householdID)
            if !granted {
                // The system prompt was declined; the toggle falls back and
                // says why rather than pretending.
                isOn = false
                wasDeclined = true
            }
        } else {
            await mirror.disable(for: householdID)
        }
    }
}
