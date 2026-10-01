import Foundation
import os

/// Where fetched data sets wait to become current, and the memory of which
/// one is.
///
/// Laid out in one folder (INGREDIENTS-DATA §5, "Client"):
///
///     <root>/<dataVersion>/        a staged set: its manifest, its files,
///                                  and `.staged`, written last
///     <root>/active.json           the pointer: the set the app chose at
///                                  its last cold start, and its fallback
///     <root>/bad.json              versions that failed their checks once,
///                                  never tried again
///     <root>/.staging-<uuid>/      a set on its way in; never read
///
/// **Only the app activates.** It chooses, marks, moves the pointer and
/// prunes, once per cold start (``activate()``). The share extension reads
/// the pointer and runs on what it names (``follow()``), and never writes
/// here: two processes launching at once would otherwise decide twice, and
/// could decide differently.
///
/// Fetching is phase 9. What this type offers it is ``stage(_:)``, which
/// takes a finished folder in whole or not at all.
public struct DataSetStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The app's and its extensions' store: in the App Group on iOS, and on
    /// the Mac, which has none, in Application Support beside the stores.
    public static var shared: DataSetStore {
        DataSetStore(root: (SousAppGroup.url ?? .applicationSupportDirectory)
            .appending(path: "Data", directoryHint: .isDirectory))
    }

    /// What the app chose at its last cold start.
    public struct Pointer: Codable, Hashable, Sendable {
        /// The version running, bundled or stored.
        public var dataVersion: Int
        /// Whether it runs from a folder here rather than from the bundle.
        public var stored: Bool
        /// The stored set kept beside it, the one that ran before.
        public var fallback: Int?
    }

    private static let log = Logger(subsystem: "me.raddatz.sous", category: "data")
    private static let stagedMarker = ".staged"

    // MARK: - Reading

    public var pointer: Pointer? {
        guard let data = try? Data(contentsOf: pointerURL) else { return nil }
        return try? JSONDecoder().decode(Pointer.self, from: data)
    }

    public var badVersions: Set<Int> {
        guard let data = try? Data(contentsOf: badURL),
              let versions = try? JSONDecoder().decode([Int].self, from: data)
        else { return [] }
        return Set(versions)
    }

    /// The versions staged here completely, newest first.
    public var stagedVersions: [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        return names.compactMap(Int.init)
            .filter { FileManager.default.fileExists(atPath: marker(for: $0).path(percentEncoded: false)) }
            .sorted(by: >)
    }

    public func folder(for version: Int) -> URL {
        root.appending(path: String(version), directoryHint: .isDirectory)
    }

    // MARK: - Staging

    /// Takes a finished set in: checked whole, copied under a temporary
    /// name, renamed to its version in one step, and marked staged last. A
    /// set that fails any check never appears under its name, and neither
    /// does half of one. It becomes current at the app's next cold start.
    @discardableResult
    public func stage(_ source: URL) throws -> Int {
        let fileManager = FileManager.default
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: source.appending(path: DataSetManifest.fileName))
        } catch {
            throw DataSetRejection.missing(file: DataSetManifest.fileName)
        }
        let version = try DataSetManifest(json: manifestData).dataVersion
        let destination = folder(for: version)
        if fileManager.fileExists(atPath: marker(for: version).path(percentEncoded: false)) {
            return version
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let copy = staging.appending(path: String(version), directoryHint: .isDirectory)
        try fileManager.copyItem(at: source, to: copy)
        // The marker is this store's to write, not the source's.
        try? fileManager.removeItem(at: copy.appending(path: Self.stagedMarker))
        _ = try DataSet.candidate(at: copy)

        // A folder under the name without the marker is a staging that
        // stopped before its last step.
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: copy, to: destination)
        try Data().write(to: marker(for: version), options: .atomic)
        return version
    }

    // MARK: - Choosing, at launch

    /// Chooses the set this process runs on: the newest staged set newer
    /// than the bundled one that passes every check, else the bundled one.
    /// A set that fails is marked bad and never tried again; one in a format
    /// this build does not read is only passed over. Then the pointer names
    /// the choice and the set that ran before it, and every other folder
    /// goes. **The app's alone** — see the type's comment.
    public func activate(bundledVersion: Int = DataSetManifest.bundled.dataVersion) -> DataSet {
        let previous = pointer
        var bad = badVersions
        var chosen: DataSet?
        for version in stagedVersions where version > bundledVersion && !bad.contains(version) {
            do {
                chosen = try DataSet.candidate(at: folder(for: version))
                break
            } catch {
                Self.log.error("Data set \(version) rejected: \(String(describing: error))")
                if error.marksBad { bad.insert(version) }
            }
        }
        if bad != badVersions {
            write(bad.sorted(), to: badURL)
        }

        let set = chosen ?? .bundled
        let stored = chosen != nil
        var fallback: Int?
        if let previous, previous.stored, previous.dataVersion != set.dataVersion {
            fallback = previous.dataVersion
        } else if let previous, previous.dataVersion == set.dataVersion {
            fallback = previous.fallback
        }
        if let kept = fallback, kept <= bundledVersion || bad.contains(kept) { fallback = nil }
        let now = Pointer(dataVersion: set.dataVersion, stored: stored, fallback: fallback)
        if now != previous {
            write(now, to: pointerURL)
        }
        prune(keeping: now, bad: bad)
        return set
    }

    /// The set the pointer names, for a process that must not choose: the
    /// share extension. Falls back to the bundled set where the pointer is
    /// missing, names an older set than the bundle, or names one that no
    /// longer passes — and writes nothing either way.
    public func follow(bundledVersion: Int = DataSetManifest.bundled.dataVersion) -> DataSet {
        guard let pointer, pointer.stored, pointer.dataVersion > bundledVersion,
              let set = try? DataSet.candidate(at: folder(for: pointer.dataVersion))
        else { return .bundled }
        return set
    }

    /// Everything here but the running set, its fallback, and staged sets
    /// newer than both (a format only a newer build reads) goes: leftovers of
    /// a staging, bad sets, sets the bundle overtook.
    private func prune(keeping pointer: Pointer, bad: Set<Int>) {
        let fileManager = FileManager.default
        let staged = Set(stagedVersions)
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        for name in names {
            let keep: Bool
            if name.hasPrefix(".staging-") {
                keep = false
            } else if let version = Int(name) {
                keep = staged.contains(version) && !bad.contains(version) && (
                    (pointer.stored && version == pointer.dataVersion)
                        || version == pointer.fallback
                        || version > pointer.dataVersion
                )
            } else {
                keep = true
            }
            if !keep {
                try? fileManager.removeItem(at: root.appending(path: name))
            }
        }
    }

    // MARK: - Files

    private var pointerURL: URL { root.appending(path: "active.json") }
    private var badURL: URL { root.appending(path: "bad.json") }

    private func marker(for version: Int) -> URL {
        folder(for: version).appending(path: Self.stagedMarker)
    }

    /// Replaced in one step, so a reader never sees half of it.
    private func write(_ value: some Encodable, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Self.log.error("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
