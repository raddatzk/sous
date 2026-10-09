import Foundation
import Security

/// A provider with the key to use it: what a person (later a household) sets
/// up once to let Sous ask a chat model itself.
///
/// Stored as one unit, key included, so the provider and the model chosen
/// travel with the key to the cook's other devices.
public struct AIConnection: Codable, Equatable, Sendable {
    public var provider: LLMProvider
    public var apiKey: String
    /// When the cook last confirmed that the key goes to this address: when
    /// they set the connection up, or accepted a move of it. `nil` for one
    /// saved before this was kept.
    public var addressConfirmedAt: Date?

    public init(provider: LLMProvider, apiKey: String, addressConfirmedAt: Date? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.addressConfirmedAt = addressConfirmedAt
    }

    /// Where the key goes: the host of the saved address, for the cook to read.
    public var host: String { provider.baseURL.host() ?? provider.baseURL.absoluteString }

    /// Whether it can ask: a model is named, and the key is there unless the
    /// endpoint is a local server, which runs without one.
    public var isUsable: Bool {
        !provider.model.isEmpty && (!apiKey.isEmpty || provider.isLocal)
    }

    public func client(session: URLSession = .shared) -> LLMClient {
        LLMClient(provider: provider, apiKey: apiKey, session: session)
    }
}

extension LLMProvider {
    /// A server on this machine or this network, which needs no key.
    public var isLocal: Bool {
        guard let host = baseURL.host() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}

/// Where a connection is kept.
public protocol AIConnectionStore: Sendable {
    func load() throws -> AIConnection?
    func save(_ connection: AIConnection) throws
    func delete() throws
}

/// Where a household's connection is kept: shared by all its members and
/// read from whichever household is showing.
public protocol HouseholdAIConnectionStore: Sendable {
    func load() async throws -> AIConnection?
    func save(_ connection: AIConnection) async throws
    func delete() async throws
}

/// For tests and previews.
public final class InMemoryAIConnectionStore: AIConnectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: AIConnection?

    public init(_ connection: AIConnection? = nil) { self.connection = connection }

    public func load() throws -> AIConnection? { lock.withLock { connection } }
    public func save(_ connection: AIConnection) throws { lock.withLock { self.connection = connection } }
    public func delete() throws { lock.withLock { connection = nil } }
}

/// The cook's own connection, in the iCloud Keychain: it follows them to
/// their other devices and to no one else. A key never goes into
/// `UserDefaults`, a backup or the household's data.
public struct KeychainAIConnectionStore: AIConnectionStore {
    public struct Failure: Error, Equatable {
        public let status: OSStatus
    }

    private let service: String
    private let account: String

    public init(service: String = "me.raddatz.sous.ai-connection", account: String = "personal") {
        self.service = service
        self.account = account
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() throws -> AIConnection? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        // An item this version cannot read is treated as absent rather than
        // fatal; the cook enters the key again.
        return try? JSONDecoder().decode(AIConnection.self, from: data)
    }

    public func save(_ connection: AIConnection) throws {
        try delete()
        var item = identity
        item[kSecAttrSynchronizable as String] = true
        item[kSecValueData as String] = try JSONEncoder().encode(connection)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}


/// The catalog names another address for a provider than the one a cook
/// saved a key with. The key stays with the saved address until the cook
/// has looked at both and said so.
public struct AddressMove: Equatable, Sendable {
    public let providerName: String
    /// What the connection holds.
    public let from: URL
    /// What the catalog says now.
    public let to: URL
    /// Where the provider announces the move and why, if the catalog says.
    public let source: URL?
    public let reason: String?
    /// The provider's own page that names its address, for the cook to check.
    public let docs: URL

    public var fromHost: String { from.host() ?? from.absoluteString }
    public var toHost: String { to.host() ?? to.absoluteString }
}

extension AIConnection {
    /// The catalog entry this connection is the provider of: by the id it was
    /// made with, or, for one saved before ids, by the address it holds when
    /// that is the catalog's current or a recorded earlier one. Never by name:
    /// a cook's own server may be called anything.
    func catalogEntry(in catalog: AIProviderCatalog) -> AIProviderCatalog.Entry? {
        if let id = provider.catalogID { return catalog.entry(id: id) }
        let saved = Self.normalized(provider.baseURL)
        return catalog.asking.first { entry in
            guard let api = entry.api else { return false }
            return Self.normalized(api.baseURL) == saved
                || api.moved.contains { Self.normalized($0.from) == saved }
        }
    }

    /// What the cook has to decide, or `nil` where the address is the catalog's.
    public func pendingMove(in catalog: AIProviderCatalog = .current) -> AddressMove? {
        guard let entry = catalogEntry(in: catalog), let api = entry.api,
            Self.normalized(api.baseURL) != Self.normalized(provider.baseURL)
        else { return nil }
        let announced = api.moved.first { Self.normalized($0.from) == Self.normalized(provider.baseURL) }
        return AddressMove(
            providerName: entry.name, from: provider.baseURL, to: api.baseURL,
            source: announced?.source, reason: announced?.reason, docs: api.docs)
    }

    /// The connection after the cook accepted `move`: the same key, at the new
    /// address, confirmed now.
    public func following(_ move: AddressMove, at date: Date = .now) -> AIConnection {
        var followed = self
        followed.provider.baseURL = move.to
        followed.provider.catalogID = followed.provider.catalogID ?? catalogEntry(in: .current)?.id
        followed.addressConfirmedAt = date
        return followed
    }

    /// Scheme, host and path, as one compares addresses: case and a trailing
    /// slash do not make another address.
    static func normalized(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        return "\(url.scheme?.lowercased() ?? "")://\(url.host()?.lowercased() ?? "")\(url.port.map { ":\($0)" } ?? "")\(path)"
    }
}
