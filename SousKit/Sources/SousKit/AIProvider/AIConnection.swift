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

    public init(provider: LLMProvider, apiKey: String) {
        self.provider = provider
        self.apiKey = apiKey
    }

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
