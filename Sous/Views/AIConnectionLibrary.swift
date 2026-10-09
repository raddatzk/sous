import SousKit
import SwiftUI

/// What the settings page for a connection needs of the place it is kept,
/// the cook's own or the household's.
@MainActor
protocol AIConnectionEditing: AnyObject {
    var connection: AIConnection? { get }
    var storeError: String? { get }
    var isHousehold: Bool { get }
    func reload()
    func save(_ connection: AIConnection)
    func remove()
}

/// The cook's own connection to a chat provider, kept in the iCloud
/// Keychain. One instance for the app: the settings write it, the sheets
/// that ask a model read it.
@MainActor @Observable
final class AIConnectionLibrary: AIConnectionEditing {
    let isHousehold = false
    static let shared = AIConnectionLibrary(store: KeychainAIConnectionStore())

    private let store: any AIConnectionStore
    private(set) var connection: AIConnection?
    /// Why the keychain could not be read or written, for the settings to say.
    private(set) var storeError: String?

    init(store: any AIConnectionStore) {
        self.store = store
        reload()
    }

    /// The connection if it can ask.
    var usable: AIConnection? { connection.flatMap { $0.isUsable ? $0 : nil } }

    /// Reads the keychain again: another device may have changed it since.
    func reload() {
        do {
            connection = try store.load()
            storeError = nil
        } catch {
            storeError = "Der Schlüsselbund ließ sich nicht lesen."
        }
    }

    func save(_ connection: AIConnection) {
        do {
            try store.save(connection)
            self.connection = connection
            storeError = nil
        } catch {
            storeError = "Der Schlüssel ließ sich nicht im Schlüsselbund speichern."
        }
    }

    func remove() {
        do {
            try store.delete()
            connection = nil
            storeError = nil
        } catch {
            storeError = "Der Schlüssel ließ sich nicht aus dem Schlüsselbund entfernen."
        }
    }
}


/// The household's connection, for every member, kept in the household's
/// rows (the key encrypted in CloudKit). The household showing decides which
/// one this is, so it is read again at a switch and whenever something syncs.
@MainActor @Observable
final class HouseholdAIConnectionLibrary: AIConnectionEditing {
    static let shared = HouseholdAIConnectionLibrary()

    let isHousehold = true
    private var store: (any HouseholdAIConnectionStore)?
    private(set) var connection: AIConnection?
    private(set) var storeError: String?

    /// Set once, when the app has its stores.
    func configure(store: any HouseholdAIConnectionStore) {
        self.store = store
        reload()
    }

    var usable: AIConnection? { connection.flatMap { $0.isUsable ? $0 : nil } }

    func reload() {
        Task { await reloadNow() }
    }

    func reloadNow() async {
        guard let store else { return }
        do {
            connection = try await store.load()
            storeError = nil
        } catch {
            storeError = "Die Verbindung des Haushalts ließ sich nicht lesen."
        }
    }

    func save(_ connection: AIConnection) {
        guard let store else { return }
        self.connection = connection
        Task {
            do {
                try await store.save(connection)
                storeError = nil
            } catch {
                storeError = "Die Verbindung ließ sich im Haushalt nicht speichern."
            }
        }
    }

    func remove() {
        guard let store else { return }
        connection = nil
        Task {
            do {
                try await store.delete()
                storeError = nil
            } catch {
                storeError = "Die Verbindung ließ sich nicht aus dem Haushalt entfernen."
            }
        }
    }
}

/// Which connection asks: the cook's own where there is one, else the
/// household's. Where both exist, the household's is the other one to offer
/// when the cook's is refused or used up. It is never taken without asking,
/// because then someone else pays.
@MainActor @Observable
final class AIConnections {
    static let shared = AIConnections()

    struct Resolved {
        enum Source { case personal, household }

        let connection: AIConnection
        let source: Source

        /// Who pays, for the sheet to say.
        var payer: String {
            switch source {
            case .personal: "Dein Schlüssel zahlt."
            case .household: "Der Schlüssel des Haushalts zahlt."
            }
        }
    }

    let personal = AIConnectionLibrary.shared
    let household = HouseholdAIConnectionLibrary.shared

    var active: Resolved? {
        if let connection = personal.usable { return Resolved(connection: connection, source: .personal) }
        if let connection = household.usable { return Resolved(connection: connection, source: .household) }
        return nil
    }

    /// What the cook has to decide about the address of the connection that
    /// asks, if the catalog has moved on from the one it was saved with.
    func pendingMove(for resolved: Resolved) -> AddressMove? {
        resolved.connection.pendingMove()
    }

    /// The cook looked and said yes: the key follows the move, in the place it
    /// is kept. For the household's, that is the shared row, so one member's
    /// yes is everyone's.
    func accept(_ move: AddressMove, for resolved: Resolved) {
        let followed = resolved.connection.following(move)
        switch resolved.source {
        case .personal: personal.save(followed)
        case .household: household.save(followed)
        }
    }

    /// The household's, where the cook's own is the one asking.
    var alternative: Resolved? {
        guard active?.source == .personal, let connection = household.usable else { return nil }
        return Resolved(connection: connection, source: .household)
    }
}
