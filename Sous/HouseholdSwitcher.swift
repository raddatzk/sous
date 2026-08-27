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
    /// `nil` is the person's own household — also while it does not exist
    /// yet, which is what an invitation-only member's app looks like.
    private(set) var activeID: UUID?
    /// Set when an invitation was just accepted: the next household to appear
    /// in the shared store is the one the person is waiting to see.
    var expectingJoin = false

    private let households: CoreDataHouseholds
    private let onSwitch: @MainActor () async -> Void

    private static let defaultsKey = "activeHouseholdID"

    init(households: CoreDataHouseholds, onSwitch: @escaping @MainActor () async -> Void) {
        self.households = households
        self.onSwitch = onSwitch
        // Restored before anything reads a store, so the first fetch of the
        // session already looks at the household the last session ended in.
        activeID = UserDefaults.sous.string(forKey: Self.defaultsKey).flatMap(UUID.init(uuidString:))
        ActiveHousehold.id = activeID
    }

    /// The joined household's name for the title — `nil` while the own one
    /// is active, where the screen keeps its ordinary name.
    var activeName: String? {
        guard let activeID else { return nil }
        return choices.first { $0.id == activeID }?.name
    }

    var hasJoined: Bool { choices.contains { !$0.isOwn } }

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

        // An active household that disappeared — left, revoked, or the
        // account changed — falls back to the person's own rather than
        // showing an empty screen with a stale name over it.
        if let activeID, !choices.contains(where: { $0.id == activeID }) {
            await switchTo(nil)
        }
    }

    func switchTo(_ id: UUID?) async {
        // The own household is represented as nil, whatever its row's id is.
        let target = choices.first(where: { $0.id == id })?.isOwn == true ? nil : id
        guard target != activeID else { return }
        activeID = target
        ActiveHousehold.id = target
        UserDefaults.sous.set(target?.uuidString, forKey: Self.defaultsKey)
        await onSwitch()
    }
}

extension EnvironmentValues {
    /// Optional, because the Mac's Settings scene builds its form with no
    /// environment at all.
    @Entry var householdSwitcher: HouseholdSwitcher?
}
