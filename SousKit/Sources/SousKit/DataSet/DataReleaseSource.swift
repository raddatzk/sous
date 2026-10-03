import Foundation

/// What the publisher says is the current release of one format: the record
/// `current-v<schema>` in the public database (INGREDIENTS-DATA §5).
///
/// Small on purpose — the daily check reads only this. The manifest carries
/// every file's hash, so the files that did not change are never fetched.
public struct ReleasePointer: Hashable, Sendable {
    /// The format, as the manifest names it.
    public var schema: Int
    public var dataVersion: Int
    /// The release's `manifest.json`, byte for byte as the compiler wrote it.
    public var manifest: Data
    /// The record name of the `DataRelease` holding the files.
    public var release: String
    /// The oldest app build that may take this release; content that needs
    /// code (a new unit, say) sets it. Nil for any build.
    public var minApp: Int?

    public init(schema: Int, dataVersion: Int, manifest: Data, release: String, minApp: Int? = nil) {
        self.schema = schema
        self.dataVersion = dataVersion
        self.manifest = manifest
        self.release = release
        self.minApp = minApp
    }
}

/// Where published releases come from: CloudKit's public database in the
/// app (``CloudKitReleaseSource``), a stand-in in the tests.
public protocol DataReleaseSource: Sendable {
    /// The pointer for a format, or nil while nothing is published for it.
    func pointer(schema: Int) async throws(DataFetchError) -> ReleasePointer?

    /// Writes the named files of a release into `folder`, each under its own
    /// name. Unchecked: the caller holds the hashes.
    func download(release: String, files: [String], into folder: URL) async throws(DataFetchError)
}

/// Why a check ended without an answer. None of them is shown to the cook:
/// the bundled set or the last fetched one keeps running, and the next check
/// that is due tries again.
public enum DataFetchError: Error, Hashable, Sendable {
    /// The server asked to be left alone for a while (`requestRateLimited`,
    /// `zoneBusy`, `serviceUnavailable`), for this long if it said.
    case throttled(retryAfter: TimeInterval?)
    /// No network. Nothing was asked, so the next launch asks again.
    case offline
    /// A record that is not the publisher's, or not of the type it should
    /// be: a name taken by somebody else, or a role set wrong.
    case untrusted
    /// Anything else — a release the pointer names that is not there yet,
    /// a field missing, a server error.
    case failed(String)
}
