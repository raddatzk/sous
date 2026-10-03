import Foundation
import Testing
@testable import SousKit

/// Switching the data set (INGREDIENTS-DATA §5, "Client"; plan phase 8): a
/// staged set is taken in whole or not at all, becomes current at the app's
/// next "launch" if it is newer than the bundle and passes every check, is
/// marked bad when it does not, and is never chosen by the share extension.
///
/// The fixtures are the bundled files themselves, copied into a temporary
/// store and changed where a test needs a set to differ — never a second,
/// hand-kept copy of the data. Everything else in the suite runs on the
/// bundled set, which is what `DataSet.current` is in a process nobody
/// launched.
@Suite("Data set")
struct DataSetTests {
    /// A temporary store, and a folder beside it to build sets in. Shared
    /// with the fetching tests.
    struct Scratch {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "sous-dataset-\(UUID().uuidString)", directoryHint: .isDirectory)
        var store: DataSetStore { DataSetStore(root: base.appending(path: "Data", directoryHint: .isDirectory)) }

        /// A complete set under `version`, from the bundled files with
        /// `edit` applied, its manifest hashing whatever the files then are.
        func set(
            _ version: Int,
            schema: Int = DataSetManifest.supportedSchema,
            edit: (inout [String: Data]) throws -> Void = { _ in }
        ) throws -> URL {
            var files: [String: Data] = [:]
            for file in DataSet.File.allCases {
                let url = try #require(DataSet.bundledURL(of: file.fileName))
                files[file.fileName] = try Data(contentsOf: url)
            }
            try edit(&files)
            let folder = base.appending(path: "built-\(UUID().uuidString)/\(version)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, data) in files {
                try data.write(to: folder.appending(path: name))
            }
            let hashes = files.mapValues(DataSetManifest.sha256(of:))
            let manifest = DataSetManifest(
                schema: schema, dataVersion: version,
                sha256: DataSetManifest.digest(of: hashes), files: hashes
            )
            try JSONEncoder().encode(manifest).write(to: folder.appending(path: DataSetManifest.fileName))
            return folder
        }

        /// Puts a set straight into the store, marker included — for a set
        /// `stage` would refuse, as a newer build or a damaged disk leaves one.
        func place(_ folder: URL) throws {
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            let destination = store.folder(for: Int(folder.lastPathComponent)!)
            try FileManager.default.copyItem(at: folder, to: destination)
            try Data().write(to: destination.appending(path: ".staged"))
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    private static let bundled = DataSetManifest.bundled.dataVersion

    /// Kitchen words with one word more, so a test can tell which set it got.
    static func addingWord(_ name: String) -> (inout [String: Data]) throws -> Void {
        { files in
            var words = try #require(
                try JSONSerialization.jsonObject(with: files["kitchen_words.json"]!) as? [[String: Any]]
            )
            words.append(["name": name, "id": name.lowercased()])
            files["kitchen_words.json"] = try JSONSerialization.data(withJSONObject: words)
        }
    }

    // MARK: - Launch

    @Test("Nobody launched: the process runs on the bundled set")
    func unlaunchedProcessRunsOnTheBundle() {
        #expect(DataSet.current === DataSet.bundled)
        #expect(IngredientCatalog.current.ingredients.count == IngredientCatalog.bundled.ingredients.count)
        #expect(RecipeContentHash.dataFingerprint == DataSet.bundled.fingerprint)
    }

    @Test("A newer valid set becomes current at launch")
    func newerSetActivates() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        try scratch.store.stage(scratch.set(version, edit: Self.addingWord("Testwurzel")))

        let set = scratch.store.activate()

        #expect(set.dataVersion == version)
        #expect(set.origin == .stored(scratch.store.folder(for: version)))
        #expect(set.catalog.ingredient(for: "Testwurzel") != nil)
        #expect(DataSet.bundled.catalog.ingredient(for: "Testwurzel") == nil)
        #expect(scratch.store.pointer == .init(dataVersion: version, stored: true, fallback: nil))
    }

    @Test("A set's own rename map is the one its catalog reads through")
    func renamesTravelWithTheSet() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let tomato = try #require(DataSet.bundled.catalog.ingredient(for: "Tomate")?.catalogID)
        let version = Self.bundled + 1
        try scratch.store.stage(scratch.set(version) { files in
            files["ids.json"] = try JSONEncoder().encode(CatalogRenames(renamed: ["paradeiser-alt": tomato]))
        })

        let set = scratch.store.activate()

        #expect(set.catalog.resolve(id: "paradeiser-alt").ingredient?.catalogID == tomato)
        #expect(DataSet.bundled.catalog.resolve(id: "paradeiser-alt") == .unknown)
    }

    // MARK: - Rejected sets

    @Test("A set whose bytes are not the manifest's is marked bad, and the bundle runs")
    func wrongHashFallsBack() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        try scratch.store.stage(scratch.set(version))
        // Damaged after staging: one byte more on disk.
        let file = scratch.store.folder(for: version).appending(path: "measures.json")
        var bytes = try Data(contentsOf: file)
        bytes.append(0x20)
        try bytes.write(to: file)

        let set = scratch.store.activate()

        #expect(set === DataSet.bundled)
        #expect(scratch.store.badVersions == [version])
        #expect(scratch.store.pointer == .init(dataVersion: Self.bundled, stored: false, fallback: nil))
        #expect(!scratch.exists(scratch.store.folder(for: version)), "a bad set is pruned")
    }

    @Test("A bad version is not tried again, even staged anew")
    func badVersionIsNotRetried() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        try scratch.place(scratch.set(version) { $0["curation.json"] = Data("{".utf8) })
        #expect(scratch.store.activate() === DataSet.bundled)
        #expect(scratch.store.badVersions == [version])

        // The same version again, intact this time: remembered as bad.
        try scratch.store.stage(scratch.set(version))
        #expect(scratch.store.activate() === DataSet.bundled)
    }

    @Test("A file that does not decode rejects the whole set")
    func undecodableFileFallsBack() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        // Hashes match: the manifest was written over the broken bytes.
        let broken = try scratch.set(version) { $0["kitchen_words.json"] = Data("[{\"name\": 1}]".utf8) }
        #expect(throws: DataSetRejection.unreadable(file: "kitchen_words.json")) {
            try scratch.store.stage(broken)
        }
        try scratch.place(broken)

        #expect(scratch.store.activate() === DataSet.bundled)
        #expect(scratch.store.badVersions == [version])
    }

    @Test("A set in an unknown format is passed over, not marked, and kept for a newer build")
    func unknownSchemaFallsBack() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        let newer = try scratch.set(version, schema: DataSetManifest.supportedSchema + 1)
        #expect(throws: DataSetRejection.unknownSchema(DataSetManifest.supportedSchema + 1)) {
            try scratch.store.stage(newer)
        }
        try scratch.place(newer)

        #expect(scratch.store.activate() === DataSet.bundled)
        #expect(scratch.store.badVersions.isEmpty)
        #expect(scratch.exists(scratch.store.folder(for: version)))
    }

    @Test("The newest set that passes wins; a broken newer one does not take an older good one down")
    func olderGoodSetStandsIn() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        try scratch.store.stage(scratch.set(Self.bundled + 1, edit: Self.addingWord("Testwurzel")))
        try scratch.place(scratch.set(Self.bundled + 2) { $0["sources.json"] = Data("[]".utf8) })

        let set = scratch.store.activate()

        #expect(set.dataVersion == Self.bundled + 1)
        #expect(scratch.store.badVersions == [Self.bundled + 2])
    }

    // MARK: - Bundle against cache

    @Test("A newer bundled set beats an older staged one, as after an app update")
    func newerBundleWins() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let older = Self.bundled - 1
        try scratch.store.stage(scratch.set(older, edit: Self.addingWord("Testwurzel")))

        let set = scratch.store.activate()

        #expect(set === DataSet.bundled)
        #expect(scratch.store.badVersions.isEmpty, "overtaken is not bad")
        #expect(!scratch.exists(scratch.store.folder(for: older)), "a set the bundle overtook is pruned")
    }

    @Test("The same version bundled and staged: the bundle is read")
    func equalVersionTakesTheBundle() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        try scratch.store.stage(scratch.set(Self.bundled))
        #expect(scratch.store.activate() === DataSet.bundled)
    }

    @Test("The set that ran before is kept as the fallback, and the one before that goes")
    func previousSetIsTheFallback() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let (first, second, third) = (Self.bundled + 1, Self.bundled + 2, Self.bundled + 3)
        try scratch.store.stage(scratch.set(first))
        _ = scratch.store.activate()
        try scratch.store.stage(scratch.set(second))
        _ = scratch.store.activate()
        #expect(scratch.store.pointer == .init(dataVersion: second, stored: true, fallback: first))

        // An unchanged launch keeps what it had.
        _ = scratch.store.activate()
        #expect(scratch.store.pointer == .init(dataVersion: second, stored: true, fallback: first))

        try scratch.store.stage(scratch.set(third))
        _ = scratch.store.activate()
        #expect(scratch.store.pointer == .init(dataVersion: third, stored: true, fallback: second))
        #expect(scratch.store.stagedVersions == [third, second])
    }

    // MARK: - Staging

    @Test("Staging is all or nothing: a set that fails leaves no trace under its name")
    func stagingIsAllOrNothing() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        let source = try scratch.set(version)
        try FileManager.default.removeItem(at: source.appending(path: "bls.json"))

        #expect(throws: DataSetRejection.missing(file: "bls.json")) {
            try scratch.store.stage(source)
        }
        #expect(!scratch.exists(scratch.store.folder(for: version)))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: scratch.store.root.path(percentEncoded: false))) ?? []
        #expect(left.isEmpty, "no staging folder left behind: \(left)")
        #expect(scratch.store.stagedVersions.isEmpty)
    }

    @Test("A folder under a version's name without the marker is not a set")
    func unmarkedFolderIsIgnored() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        try FileManager.default.createDirectory(at: scratch.store.root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: scratch.set(version), to: scratch.store.folder(for: version))

        #expect(scratch.store.stagedVersions.isEmpty)
        #expect(scratch.store.activate() === DataSet.bundled)
        #expect(!scratch.exists(scratch.store.folder(for: version)), "a half-staged folder is pruned")
    }

    // MARK: - Only the app activates

    @Test("The share extension runs on the pointer's set and never activates")
    func extensionOnlyFollows() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        try scratch.store.stage(scratch.set(version, edit: Self.addingWord("Testwurzel")))

        // Staged, but the app has not launched since: the extension stays on
        // the bundle and writes nothing.
        #expect(scratch.store.follow() === DataSet.bundled)
        #expect(scratch.store.pointer == nil)
        #expect(scratch.store.stagedVersions == [version])

        _ = scratch.store.activate()
        let followed = scratch.store.follow()
        #expect(followed.dataVersion == version)
        #expect(followed.catalog.ingredient(for: "Testwurzel") != nil)
    }

    @Test("A broken set under the pointer sends the extension to the bundle, unmarked")
    func extensionDoesNotMarkBad() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        try scratch.store.stage(scratch.set(version))
        _ = scratch.store.activate()
        try FileManager.default.removeItem(at: scratch.store.folder(for: version).appending(path: "ids.json"))

        #expect(scratch.store.follow() === DataSet.bundled)
        #expect(scratch.store.badVersions.isEmpty, "marking is the app's")
        #expect(scratch.store.pointer?.dataVersion == version, "and so is the pointer")
    }

    // MARK: - The fingerprint

    @Test("The fingerprint moves with the set, and every cached figure with it")
    func fingerprintFollowsTheSet() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let version = Self.bundled + 1
        try scratch.store.stage(scratch.set(version))
        let set = scratch.store.activate()

        #expect(DataSet.bundled.fingerprint == "r\(RecipeContentHash.readingVersion)-\(Self.bundled)")
        #expect(set.fingerprint == "r\(RecipeContentHash.readingVersion)-\(version)")

        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "2 Tomaten")
        #expect(
            RecipeContentHash.hash(for: recipe, dataFingerprint: set.fingerprint)
                != RecipeContentHash.hash(for: recipe, dataFingerprint: DataSet.bundled.fingerprint)
        )

        // And the marker the reconciliation reads sees a change.
        let suite = "sous.tests.dataset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = BundledDataMarker(defaults: defaults)
        marker.record(BundledDataStamp(fingerprint: DataSet.bundled.fingerprint, datasetVersion: "BLS 4.0", seenAt: .now))
        #expect(marker.hasChanged(from: BundledDataStamp(fingerprint: set.fingerprint, datasetVersion: "BLS 4.0", seenAt: .now)))
    }
}
