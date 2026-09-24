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

    private let households: CoreDataHouseholds
    private let onSwitch: @MainActor () async -> Void

    private static let defaultsKey = "activeHouseholdID"

    init(households: CoreDataHouseholds, onSwitch: @escaping @MainActor () async -> Void) {
        self.households = households
        self.onSwitch = onSwitch
        // Restored before anything reads a store, so the first fetch of the
        // session already looks at the household the last session ended in.
        // Nothing stored is what an update from a build with only one
        // household looks like, where `nil` meant "mine": starting in the
        // oldest own one keeps the library on screen from the first fetch.
        activeID = UserDefaults.sous.string(forKey: Self.defaultsKey).flatMap(UUID.init(uuidString:))
            ?? households.oldestOwnID()
        ActiveHousehold.id = activeID
    }

    /// The joined household's name for the title — `nil` while an own one
    /// is active, where the screen keeps its ordinary name.
    var activeName: String? {
        guard let active = choices.first(where: { $0.id == activeID }), !active.isOwn
        else { return nil }
        return active.name
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
        UserDefaults.sous.set(id?.uuidString, forKey: Self.defaultsKey)
        await onSwitch()
    }
}

extension EnvironmentValues {
    /// Optional, because the Mac's Settings scene builds its form with no
    /// environment at all.
    @Entry var householdSwitcher: HouseholdSwitcher?
}
