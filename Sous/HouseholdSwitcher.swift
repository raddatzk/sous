import Foundation
import SousKit
import SwiftUI

/// Which household the app is showing, and the switch between them.
///
/// The concept's promise made concrete: the switch is a filter over what is
/// already on the device, not an account change. Nothing signs out, nothing
/// re-downloads — `ActiveHousehold.id` changes, the libraries reload, and the
/// stores read and write somewhere else.
@MainActor
@Observable
final class HouseholdSwitcher {
    private(set) var choices: [HouseholdChoice] = []
    /// The household showing, own or joined. `nil` only while this device
    /// knows none — a reinstall before its first import — when the screens
    /// show what was saved in the meantime.
    private(set) var activeID: UUID?
    /// Set when an invitation was just accepted: the next household to appear
    /// in the shared store is the one the person is waiting to see.
    var expectingJoin = false
    /// Set while "Neuer Haushalt …" asks for a name. Here rather than in a
    /// view, because the Mac asks from the menu bar, which cannot reach a
    /// view's state.
    var isNamingNewHousehold = false
    /// Rows saved before this device knew its households, which settling
    /// could not place because there are several own ones. Shown until they
    /// have a home.
    private(set) var unassignedRows = 0
    /// Set when the person should be asked where those rows go — once per
    /// launch, and again whenever they tap the notice.
    var isAskingAboutUnassignedRows = false
    private var hasAskedAboutUnassignedRows = false
    /// The household just switched to because something from outside
    /// pointed there — named briefly over the screen, so the change does
    /// not go unnoticed. The root clears it.
    var announcement: Announcement?

    struct Announcement: Identifiable, Equatable {
        /// Fresh per switch, so a second one restarts the countdown.
        let id = UUID()
        let name: String
    }

    private let households: CoreDataHouseholds
    private let onSwitch: @MainActor () async -> Void

    init(households: CoreDataHouseholds, onSwitch: @escaping @MainActor () async -> Void) {
        self.households = households
        self.onSwitch = onSwitch
        // Restored before anything reads a store, so the first fetch of the
        // session already looks at the household the last session ended in.
        // Nothing stored is what an update from a build with only one
        // household looks like, where `nil` meant "mine": starting in the
        // oldest own one keeps the library on screen from the first fetch.
        activeID = ActiveHousehold.remembered ?? households.oldestOwnID()
        ActiveHousehold.id = activeID
    }

    /// The active household's name, for under a screen's title — once there
    /// is more than one to tell apart. With a single household, naming it on
    /// every screen says nothing.
    var subtitle: String? {
        guard choices.count > 1 else { return nil }
        return choices.first { $0.id == activeID }?.name
    }

    /// The households the waiting rows can go to: only own ones, since the
    /// rows sit in the private store.
    var ownChoices: [HouseholdChoice] { choices.filter(\.isOwn) }

    func refresh() async {
        choices = (try? await households.choices()) ?? choices

        // The household somebody was just invited into arrives by import,
        // moments after they accepted. Switching to it unasked is the whole
        // point of having accepted.
        if expectingJoin, let newest = choices.last(where: { !$0.isOwn }) {
            expectingJoin = false
            await switchTo(newest.id)
            return
        }

        // None active, or one that disappeared — left, revoked, or the
        // account changed — falls back to the person's oldest own household
        // rather than showing an empty screen with a stale name over it.
        // With no own household yet, there is nothing to fall back to: the
        // screens keep showing what waits for one until the first import
        // has settled.
        if !choices.contains(where: { $0.id == activeID }) {
            await switchTo(choices.first(where: \.isOwn)?.id)
        }
    }

    func switchTo(_ id: UUID?) async {
        guard id != activeID else { return }
        activeID = id
        ActiveHousehold.id = id
        UserDefaults.sous.set(id?.uuidString, forKey: ActiveHousehold.defaultsKey)
        await onSwitch()
    }

    /// Switches because a link, a handoff or a calendar event points into
    /// another household, and says so. The person did not pick it from the
    /// title menu, so the name under the title changing is too quiet on its
    /// own.
    func switchAnnounced(to id: UUID) async {
        guard id != activeID else { return }
        // A link tapped at launch can arrive before the first refresh has
        // listed anything to name.
        if !choices.contains(where: { $0.id == id }) {
            choices = (try? await households.choices()) ?? choices
        }
        // Before the switch rather than after: the libraries reload while
        // it shows, and the name is what explains the screen changing.
        announcement = choices.first { $0.id == id }.map { Announcement(name: $0.name) }
        await switchTo(id)
    }

    /// Makes a household with this name and shows it — empty, ready for
    /// whatever is written next.
    func create(named name: String) async {
        guard let id = try? await households.create(named: name) else { return }
        await refresh()
        await switchTo(id)
    }

    /// What settling left without a household. Asks where it goes the first
    /// time there is anything, not on every store change after that.
    func noteUnassigned(_ count: Int) {
        unassignedRows = count
        guard count > 0, !hasAskedAboutUnassignedRows else { return }
        hasAskedAboutUnassignedRows = true
        isAskingAboutUnassignedRows = true
    }

    /// Gives the waiting rows to the household the person chose.
    func assignUnassignedRows(to id: UUID) async {
        _ = try? await households.assignWaitingRows(to: id)
        unassignedRows = (try? await households.waitingRowCount()) ?? 0
        // They showed in every own household while they waited; now they
        // belong to one, and the others should stop showing them.
        await onSwitch()
    }
}

extension EnvironmentValues {
    /// Optional, because the Mac's Settings scene builds its form with no
    /// environment at all.
    @Entry var householdSwitcher: HouseholdSwitcher?
}
