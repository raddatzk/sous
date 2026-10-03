import Foundation
import os
import Synchronization

/// The daily check for newer catalog data (INGREDIENTS-DATA §5, "Client";
/// plan phase 9).
///
/// At most once in ``interval``, the app reads the pointer for the format it
/// knows. Only a release that is newer than both the running set and anything
/// already staged, in a format and for a build this app reads, and not
/// remembered as bad, is fetched — and of it only the files whose hash
/// differs from the running set's; the others are copied. Every file is
/// checked against the manifest, and the folder goes to
/// ``DataSetStore/stage(_:)``, which checks the whole set once more and takes
/// it in whole or not at all. It becomes current at the next cold start.
///
/// Nothing here is shown to the cook, and nothing retries in a loop:
/// - throttling waits as long as the server asked (an hour if it did not
///   say), then the next launch after that tries again
/// - no network records nothing, so the next launch asks again
/// - every other failure ends the check until the next one is due
///
/// **The app's alone** — never the share extension or the widgets, which
/// only follow what the app chose.
public struct DataUpdater: Sendable {
    /// "Once a day", measured on the clock rather than by calendar day, so
    /// time zones and a launch shortly before midnight do not matter.
    public static let interval: TimeInterval = 20 * 60 * 60
    /// How long throttling waits when the server does not say.
    static let defaultRetryAfter: TimeInterval = 60 * 60

    public enum Outcome: Hashable, Sendable {
        /// Checked less than ``interval`` ago, or still told to wait.
        case notDue
        /// Nothing newer than what runs or waits already.
        case upToDate
        /// Newer, but not for this build: an unknown format, a newer
        /// `minApp`, or a version that failed once.
        case passedOver(Int)
        /// Fetched and staged; current at the next cold start.
        case staged(Int)
        /// Fetched and refused: a file whose bytes are not the ones named,
        /// or a set that does not decode. Remembered as bad.
        case rejected(Int)
        /// Told to wait until then.
        case deferred(until: Date)
        /// No answer this time; see ``DataFetchError``.
        case failed(DataFetchError)
    }

    private let store: DataSetStore
    private let source: any DataReleaseSource
    private let running: DataSet
    private let schedule: DataUpdateSchedule
    private let appBuild: Int?

    /// - Parameters:
    ///   - running: the set this process runs on; files it shares with a
    ///     release are copied from it.
    ///   - appBuild: this build's number, compared with a release's `minApp`.
    public init(
        store: DataSetStore,
        source: any DataReleaseSource,
        running: DataSet = .current,
        schedule: DataUpdateSchedule = DataUpdateSchedule(),
        appBuild: Int?
    ) {
        self.store = store
        self.source = source
        self.running = running
        self.schedule = schedule
        self.appBuild = appBuild
    }

    private static let log = Logger(subsystem: "me.raddatz.sous", category: "data")
    /// The app asks at launch and whenever it comes to the front; two of
    /// those at once must not fetch twice into the same store.
    private static let inFlight = Mutex(Set<URL>())

    /// Checks if a check is due, and fetches and stages a newer release if
    /// there is one.
    @discardableResult
    public func checkIfDue(now: Date = .now) async -> Outcome {
        guard schedule.isDue(at: now) else { return .notDue }
        let root = store.root
        guard Self.inFlight.withLock({ $0.insert(root).inserted }) else { return .notDue }
        defer { Self.inFlight.withLock { _ = $0.remove(root) } }

        let outcome = await check()
        switch outcome {
        case .failed(.offline), .notDue:
            break
        case .failed(.throttled(let retryAfter)):
            let until = now.addingTimeInterval(retryAfter ?? Self.defaultRetryAfter)
            schedule.defer(until: until)
            Self.log.info("Data check throttled until \(until)")
            return .deferred(until: until)
        default:
            schedule.recordCheck(at: now)
        }
        Self.log.info("Data check: \(String(describing: outcome))")
        return outcome
    }

    private func check() async -> Outcome {
        let pointer: ReleasePointer?
        do {
            pointer = try await source.pointer(schema: DataSetManifest.supportedSchema)
        } catch {
            return .failed(error)
        }
        guard let pointer else { return .upToDate }

        let newestHere = max(running.dataVersion, store.stagedVersions.first ?? 0)
        guard pointer.dataVersion > newestHere else { return .upToDate }
        guard pointer.schema == DataSetManifest.supportedSchema,
              !store.badVersions.contains(pointer.dataVersion)
        else { return .passedOver(pointer.dataVersion) }
        if let minApp = pointer.minApp, minApp > (appBuild ?? 0) {
            return .passedOver(pointer.dataVersion)
        }

        let manifest: DataSetManifest
        do {
            manifest = try DataSetManifest(json: pointer.manifest)
        } catch {
            if !error.marksBad { return .passedOver(pointer.dataVersion) }
            store.markBad(pointer.dataVersion)
            return .rejected(pointer.dataVersion)
        }
        // The pointer and the manifest it carries must agree on what they
        // name, or the set would be staged under a version it does not have.
        guard manifest.dataVersion == pointer.dataVersion else {
            store.markBad(pointer.dataVersion)
            return .rejected(pointer.dataVersion)
        }
        return await fetch(manifest, manifestData: pointer.manifest, release: pointer.release)
    }

    private func fetch(_ manifest: DataSetManifest, manifestData: Data, release: String) async -> Outcome {
        let fileManager = FileManager.default
        let version = manifest.dataVersion
        let base = fileManager.temporaryDirectory
            .appending(path: "sous-fetch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: base) }
        let folder = base.appending(path: String(version), directoryHint: .isDirectory)
        let downloads = base.appending(path: "downloads", directoryHint: .isDirectory)

        var changed: [String] = []
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
            for (name, hash) in manifest.files.sorted(by: { $0.key < $1.key }) {
                guard !name.contains("/"), !name.hasPrefix(".") else {
                    store.markBad(version)
                    return .rejected(version)
                }
                if running.manifest.files[name] == hash, let url = running.url(of: name) {
                    try fileManager.copyItem(at: url, to: folder.appending(path: name))
                } else {
                    changed.append(name)
                }
            }
            try manifestData.write(to: folder.appending(path: DataSetManifest.fileName))
        } catch {
            return .failed(.failed("Could not prepare the folder: \(error.localizedDescription)"))
        }

        if !changed.isEmpty {
            do {
                try await source.download(release: release, files: changed, into: downloads)
            } catch {
                return .failed(error)
            }
            for name in changed {
                let downloaded = downloads.appending(path: name)
                guard let data = try? Data(contentsOf: downloaded) else {
                    return .failed(.failed("\(name) did not arrive"))
                }
                guard DataSetManifest.sha256(of: data) == manifest.files[name] else {
                    Self.log.error("Data set \(version): \(name) is not the file its manifest names")
                    store.markBad(version)
                    return .rejected(version)
                }
                do {
                    try fileManager.moveItem(at: downloaded, to: folder.appending(path: name))
                } catch {
                    return .failed(.failed("Could not keep \(name): \(error.localizedDescription)"))
                }
            }
        }

        do {
            try store.stage(folder)
            return .staged(version)
        } catch let rejection as DataSetRejection {
            Self.log.error("Data set \(version) refused at staging: \(String(describing: rejection))")
            guard rejection.marksBad else { return .passedOver(version) }
            store.markBad(version)
            return .rejected(version)
        } catch {
            return .failed(.failed("Could not stage: \(error.localizedDescription)"))
        }
    }
}

/// When the last check was, and how long the server asked to wait. Device
/// state in the shared defaults, like ``BundledDataMarker``.
public struct DataUpdateSchedule: @unchecked Sendable {
    private enum Key {
        static let lastCheck = "dataUpdate.lastCheck"
        static let notBefore = "dataUpdate.notBefore"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .sous) {
        self.defaults = defaults
    }

    /// The last check that got an answer, whatever it was.
    public var lastCheck: Date? { date(Key.lastCheck) }

    func isDue(at now: Date) -> Bool {
        if let notBefore = date(Key.notBefore), now < notBefore { return false }
        // A clock set back must not stop the checks for good.
        guard let last = lastCheck, last <= now else { return true }
        return now.timeIntervalSince(last) >= DataUpdater.interval
    }

    func recordCheck(at now: Date) {
        defaults.set(now.timeIntervalSince1970, forKey: Key.lastCheck)
        defaults.removeObject(forKey: Key.notBefore)
    }

    func `defer`(until date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Key.notBefore)
    }

    private func date(_ key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }
}
