import Foundation
import Synchronization
import Testing
@testable import SousKit

/// The daily fetch (INGREDIENTS-DATA §5, "Client"; plan phase 9), against a
/// stand-in for CloudKit that serves sets built from the bundled files.
///
/// The process runs on the bundled set, as every test does; a fetched set
/// becomes current only at the next "launch", which is
/// ``DataSetStore/activate(bundledVersion:)`` here.
@Suite("Data updater")
struct DataUpdaterTests {
    /// A published release and the pointer naming it, or a failure instead.
    final class FakeSource: DataReleaseSource {
        struct State {
            var pointer: Result<ReleasePointer?, DataFetchError> = .success(nil)
            /// The release's files, by name.
            var files: [String: Data] = [:]
            var downloadError: DataFetchError?
            var pointerReads = 0
            var downloaded: [[String]] = []
        }

        let state = Mutex(State())

        func pointer(schema: Int) async throws(DataFetchError) -> ReleasePointer? {
            let result = state.withLock { state in
                state.pointerReads += 1
                return state.pointer
            }
            return try result.get()
        }

        func download(release: String, files: [String], into folder: URL) async throws(DataFetchError) {
            let (served, error) = state.withLock { state in
                state.downloaded.append(files.sorted())
                return (state.files, state.downloadError)
            }
            if let error { throw error }
            for name in files {
                guard let data = served[name] else { throw .failed("no \(name)") }
                try? data.write(to: folder.appending(path: name))
            }
        }

        /// Publishes the set in `folder`, as `publish.py` would.
        func publish(_ folder: URL, schema: Int? = nil, minApp: Int? = nil) throws {
            let manifest = try Data(contentsOf: folder.appending(path: DataSetManifest.fileName))
            let version = try #require(Int(folder.lastPathComponent))
            var files: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            where name != DataSetManifest.fileName {
                files[name] = try Data(contentsOf: folder.appending(path: name))
            }
            state.withLock { state in
                state.pointer = .success(ReleasePointer(
                    schema: schema ?? DataSetManifest.supportedSchema, dataVersion: version,
                    manifest: manifest, release: "release-\(version)", minApp: minApp
                ))
                state.files = files
            }
        }
    }

    private static let bundled = DataSetManifest.bundled.dataVersion
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private let scratch = DataSetTests.Scratch()
    private let source = FakeSource()
    private let schedule = DataUpdateSchedule(defaults: UserDefaults(suiteName: "sous-updater-\(UUID().uuidString)")!)

    private func updater(build: Int? = 100) -> DataUpdater {
        DataUpdater(store: scratch.store, source: source, running: .bundled, schedule: schedule, appBuild: build)
    }

    // MARK: - A newer release

    @Test("A newer release is fetched — only the files that changed — staged, and current at the next launch")
    func newerReleaseIsStaged() async throws {
        defer { scratch.remove() }
        try source.publish(scratch.set(Self.bundled + 1, edit: DataSetTests.addingWord("Testwurzel")))

        let outcome = await updater().checkIfDue(now: Self.start)

        #expect(outcome == .staged(Self.bundled + 1))
        #expect(source.state.withLock { $0.downloaded } == [["kitchen_words.json"]])
        #expect(scratch.store.stagedVersions == [Self.bundled + 1])
        #expect(schedule.lastCheck == Self.start)

        let next = scratch.store.activate()
        #expect(next.dataVersion == Self.bundled + 1)
        #expect(next.catalog.ingredient(for: "Testwurzel") != nil)
    }

    @Test("The same version as the one running: nothing is fetched or staged")
    func sameVersionDoesNothing() async throws {
        defer { scratch.remove() }
        try source.publish(scratch.set(Self.bundled))

        #expect(await updater().checkIfDue(now: Self.start) == .upToDate)
        #expect(source.state.withLock { $0.downloaded }.isEmpty)
        #expect(scratch.store.stagedVersions.isEmpty)
        #expect(schedule.lastCheck == Self.start)
    }

    @Test("A release already staged is not fetched again")
    func stagedReleaseIsNotFetchedAgain() async throws {
        defer { scratch.remove() }
        let folder = try scratch.set(Self.bundled + 1)
        try scratch.store.stage(folder)
        try source.publish(folder)

        #expect(await updater().checkIfDue(now: Self.start) == .upToDate)
        #expect(source.state.withLock { $0.downloaded }.isEmpty)
    }

    @Test("Nothing published yet is an answer, not a failure")
    func nothingPublished() async {
        defer { scratch.remove() }
        #expect(await updater().checkIfDue(now: Self.start) == .upToDate)
        #expect(schedule.lastCheck == Self.start)
    }

    // MARK: - Not for this build

    @Test("A release in a format this build does not read is passed over, and not marked bad")
    func unknownSchemaIsIgnored() async throws {
        defer { scratch.remove() }
        try source.publish(scratch.set(Self.bundled + 1, schema: DataSetManifest.supportedSchema + 1),
                           schema: DataSetManifest.supportedSchema + 1)

        #expect(await updater().checkIfDue(now: Self.start) == .passedOver(Self.bundled + 1))
        #expect(source.state.withLock { $0.downloaded }.isEmpty)
        #expect(scratch.store.badVersions.isEmpty)
        #expect(scratch.store.stagedVersions.isEmpty)
    }

    @Test("A pointer that says the known format over a manifest in another is passed over too")
    func unknownSchemaInsideTheManifest() async throws {
        defer { scratch.remove() }
        try source.publish(scratch.set(Self.bundled + 1, schema: DataSetManifest.supportedSchema + 1))

        #expect(await updater().checkIfDue(now: Self.start) == .passedOver(Self.bundled + 1))
        #expect(scratch.store.badVersions.isEmpty)
    }

    @Test("A release for a newer build waits for that build")
    func newerMinAppIsIgnored() async throws {
        defer { scratch.remove() }
        try source.publish(scratch.set(Self.bundled + 1), minApp: 101)

        #expect(await updater(build: 100).checkIfDue(now: Self.start) == .passedOver(Self.bundled + 1))
        #expect(source.state.withLock { $0.downloaded }.isEmpty)
    }

    // MARK: - Refused

    @Test("A file whose bytes are not the ones its manifest names is refused, remembered, and never fetched again")
    func wrongHashIsRejected() async throws {
        defer { scratch.remove() }
        try source.publish(scratch.set(Self.bundled + 1, edit: DataSetTests.addingWord("Testwurzel")))
        source.state.withLock { $0.files["kitchen_words.json"] = Data("[]".utf8) }

        #expect(await updater().checkIfDue(now: Self.start) == .rejected(Self.bundled + 1))
        #expect(scratch.store.stagedVersions.isEmpty)
        #expect(scratch.store.badVersions == [Self.bundled + 1])
        #expect(scratch.store.activate().dataVersion == Self.bundled)

        let later = Self.start.addingTimeInterval(DataUpdater.interval)
        #expect(await updater().checkIfDue(now: later) == .passedOver(Self.bundled + 1))
        #expect(source.state.withLock { $0.downloaded }.count == 1)
    }

    @Test("A pointer whose version is not its manifest's is refused")
    func pointerAndManifestDisagree() async throws {
        defer { scratch.remove() }
        try source.publish(scratch.set(Self.bundled + 1))
        source.state.withLock { state in
            if case .success(var pointer?) = state.pointer {
                pointer.dataVersion = Self.bundled + 2
                state.pointer = .success(pointer)
            }
        }

        #expect(await updater().checkIfDue(now: Self.start) == .rejected(Self.bundled + 2))
        #expect(scratch.store.stagedVersions.isEmpty)
    }

    // MARK: - When to ask

    @Test("At most once in 20 hours, by the clock")
    func onceIn20Hours() async throws {
        defer { scratch.remove() }
        #expect(await updater().checkIfDue(now: Self.start) == .upToDate)
        #expect(await updater().checkIfDue(now: Self.start.addingTimeInterval(19 * 3600)) == .notDue)
        #expect(source.state.withLock { $0.pointerReads } == 1)
        #expect(await updater().checkIfDue(now: Self.start.addingTimeInterval(20 * 3600)) == .upToDate)
        #expect(source.state.withLock { $0.pointerReads } == 2)
    }

    @Test("Throttling waits as long as the server asks, then the next launch tries again")
    func throttlingDefers() async throws {
        defer { scratch.remove() }
        source.state.withLock { $0.pointer = .failure(.throttled(retryAfter: 300)) }

        #expect(await updater().checkIfDue(now: Self.start) == .deferred(until: Self.start.addingTimeInterval(300)))
        #expect(schedule.lastCheck == nil)
        #expect(await updater().checkIfDue(now: Self.start.addingTimeInterval(299)) == .notDue)
        #expect(source.state.withLock { $0.pointerReads } == 1)

        try source.publish(scratch.set(Self.bundled + 1))
        #expect(await updater().checkIfDue(now: Self.start.addingTimeInterval(300)) == .staged(Self.bundled + 1))
    }

    @Test("Throttled during the download waits too, an hour when the server does not say")
    func throttledDownload() async throws {
        defer { scratch.remove() }
        try source.publish(scratch.set(Self.bundled + 1, edit: DataSetTests.addingWord("Testwurzel")))
        source.state.withLock { $0.downloadError = .throttled(retryAfter: nil) }

        #expect(await updater().checkIfDue(now: Self.start) == .deferred(until: Self.start.addingTimeInterval(3600)))
        #expect(scratch.store.stagedVersions.isEmpty)
        #expect(scratch.store.badVersions.isEmpty)
    }

    @Test("Offline: nothing is recorded, the next launch asks again, and the app runs on the bundled set")
    func offlineStartsOnTheBundle() async throws {
        defer { scratch.remove() }
        source.state.withLock { $0.pointer = .failure(.offline) }

        #expect(await updater().checkIfDue(now: Self.start) == .failed(.offline))
        #expect(schedule.lastCheck == nil)
        #expect(scratch.store.activate().dataVersion == Self.bundled)
        #expect(await updater().checkIfDue(now: Self.start.addingTimeInterval(60)) == .failed(.offline))
        #expect(source.state.withLock { $0.pointerReads } == 2)
    }

    @Test("Any other failure ends the check until the next one is due")
    func otherFailureWaitsForTheNextDay() async throws {
        defer { scratch.remove() }
        source.state.withLock { $0.pointer = .failure(.untrusted) }

        #expect(await updater().checkIfDue(now: Self.start) == .failed(.untrusted))
        #expect(schedule.lastCheck == Self.start)
        #expect(await updater().checkIfDue(now: Self.start.addingTimeInterval(3600)) == .notDue)
    }
}
