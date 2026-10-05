import Foundation
import Synchronization

/// One release of the catalog data: the files `compile.py` writes, the
/// tables the app derives from them, and the manifest that names them.
///
/// The app ships one set in its bundle. Newer ones arrive later, fetched and
/// staged in a ``DataSetStore``. Which set a
/// process runs on is decided once, the first time anything reads
/// ``current``, and never changes while the process lives: every table the
/// app holds is derived from it, and a catalog swapped under a running app
/// would leave caches, indexes and open screens answering from two releases
/// at once. A new set becomes current at the next cold start instead.
public final class DataSet: Sendable {
    /// The files every set consists of.
    public enum File: String, CaseIterable, Sendable {
        case nutrition, kitchenWords = "kitchen_words", curation, measures, aisles, sources, ids

        public var fileName: String { rawValue + ".json" }
    }

    public enum Origin: Hashable, Sendable {
        case bundled
        /// Staged in a ``DataSetStore``, in this folder.
        case stored(URL)
    }

    public let manifest: DataSetManifest
    public let origin: Origin

    public let kitchenWords: KitchenWords
    public let curation: IngredientCuration
    public let aisles: AisleDefaults
    public let measures: MeasureTable
    public let bls: BLSCatalog
    public let sources: [DataSource]
    public let renames: CatalogRenames

    public let synonyms: SynonymTable
    public let catalog: IngredientCatalog
    public let nutrition: NutritionCatalog

    public var dataVersion: Int { manifest.dataVersion }

    /// What every cached figure, review mark and index entry is keyed to:
    /// `r<readingVersion>-<dataVersion>`. A new set changes it exactly as an
    /// app update with new data always did — the reconciliation reruns, the
    /// search is reindexed, and nutrition is recomputed as it is next asked.
    public var fingerprint: String {
        RecipeContentHash.fingerprint(dataVersion: dataVersion)
    }

    /// Decodes every file and derives the tables. A file that does not decode
    /// rejects the whole set: a set is used entire or not at all.
    init(
        manifest: DataSetManifest,
        origin: Origin,
        contents: (File) throws(DataSetRejection) -> Data
    ) throws(DataSetRejection) {
        func decode<T>(_ file: File, _ read: (Data) throws -> T) throws(DataSetRejection) -> T {
            let data = try contents(file)
            do { return try read(data) } catch { throw .unreadable(file: file.fileName) }
        }
        self.manifest = manifest
        self.origin = origin
        kitchenWords = try decode(.kitchenWords, KitchenWords.init(json:))
        curation = try decode(.curation, IngredientCuration.init(json:))
        aisles = try decode(.aisles, AisleDefaults.init(json:))
        measures = try decode(.measures, MeasureTable.init(json:))
        bls = try decode(.nutrition, BLSCatalog.init(nutrition:))
        sources = try decode(.sources, DataSources.decode)
        renames = try decode(.ids, CatalogRenames.init(json:))

        synonyms = SynonymTable(kitchen: kitchenWords, curation: curation)
        catalog = IngredientCatalog(ingredients: synonyms.catalogIngredients, renames: renames)
        nutrition = NutritionCatalog.make(synonyms: synonyms, bls: bls, measures: measures)
    }

    /// Checks a folder as a candidate set, the whole way: a manifest in a
    /// format this build reads, named for its own version, every file there
    /// with the bytes the manifest names, and every one of them decoding.
    ///
    /// The one check a staged set gets, at staging and again at every launch
    /// that considers it — a set staged by a newer build is read by an older
    /// one after a rollback, and a file can go missing in between.
    public static func candidate(at folder: URL) throws(DataSetRejection) -> DataSet {
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: folder.appending(path: DataSetManifest.fileName))
        } catch {
            throw .missing(file: DataSetManifest.fileName)
        }
        let manifest = try DataSetManifest(json: manifestData)
        guard folder.lastPathComponent == String(manifest.dataVersion) else { throw .misnamed }
        guard DataSetManifest.digest(of: manifest.files) == manifest.sha256 else {
            throw .hashMismatch(file: DataSetManifest.fileName)
        }

        var contents: [File: Data] = [:]
        for (name, hash) in manifest.files {
            // A name is a file in this folder, never a path out of it.
            guard !name.contains("/"), !name.hasPrefix(".") else { throw .unreadable(file: DataSetManifest.fileName) }
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else {
                throw .missing(file: name)
            }
            guard DataSetManifest.sha256(of: data) == hash else { throw .hashMismatch(file: name) }
            if let file = File.allCases.first(where: { $0.fileName == name }) {
                contents[file] = data
            }
        }
        return try DataSet(manifest: manifest, origin: .stored(folder)) { file throws(DataSetRejection) in
            guard let data = contents[file] else { throw .missing(file: file.fileName) }
            return data
        }
    }

    /// The set shipped with the app. Its files are the build's own, checked
    /// by the suite and by `compile.py --check`; one that does not decode is
    /// a broken build, not a broken download.
    public static let bundled: DataSet = {
        do {
            return try DataSet(manifest: .bundled, origin: .bundled) { file throws(DataSetRejection) in
                guard let url = bundledURL(of: file.fileName), let data = try? Data(contentsOf: url)
                else { throw .missing(file: file.fileName) }
                return data
            }
        } catch {
            preconditionFailure("The bundled data set is unreadable: \(error)")
        }
    }()

    /// Where a file of the bundled set is, by its name in the manifest.
    static func bundledURL(of fileName: String) -> URL? {
        let name = fileName as NSString
        return Bundle.module.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension)
    }

    /// Where one of this set's files is: in the bundle, or in its folder.
    /// What a fetch copies instead of downloading a file that did not change.
    func url(of fileName: String) -> URL? {
        switch origin {
        case .bundled: return Self.bundledURL(of: fileName)
        case .stored(let folder): return folder.appending(path: fileName)
        }
    }

    // MARK: - The set this process runs on

    /// What a process may do with the sets in its store.
    public enum Role: Sendable {
        /// The app: chooses the newest set that passes its checks, marks the
        /// ones that fail, moves the pointer, and prunes.
        case activates
        /// The share extension: runs on the set the pointer names, and
        /// writes nothing. Two processes deciding at the same cold start
        /// would decide differently.
        case follows
    }

    private struct Launch {
        var store: DataSetStore?
        var role: Role = .follows
        var decided = false
    }

    private static let launchState = Mutex(Launch())

    /// Says where fetched sets live and what this process may do with them.
    /// Called first thing at launch, before anything reads ``current``;
    /// without a call — in tests, say — the process runs on the bundled set.
    public static func launch(_ role: Role, store: DataSetStore?) {
        launchState.withLock { state in
            assert(!state.decided, "DataSet.launch came after something had read DataSet.current")
            state.store = store
            state.role = role
        }
    }

    /// The set this process runs on, chosen the first time anything asks.
    public static let current: DataSet = {
        let (store, role) = launchState.withLock { state in
            state.decided = true
            return (state.store, state.role)
        }
        guard let store else { return .bundled }
        switch role {
        case .activates: return store.activate()
        case .follows: return store.follow()
        }
    }()
}
