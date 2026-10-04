import CryptoKit
import Foundation

/// What a data set says about itself: which format it is written in, which
/// release it is, and what each of its files hashes to.
///
/// `manifest.json`, written by `Scripts/data/compile.py` beside the files it
/// describes. The bundled set carries one in the resources, and every set
/// fetched later carries its own, so both are one series: the
/// number the compiler gave the bundled copy is the number the same data is
/// published under.
public struct DataSetManifest: Codable, Hashable, Sendable {
    /// The format this build reads. A set in another format is skipped, never
    /// marked bad: after a rollback to an older build, the newer build that
    /// fetched it can still read it.
    public static let supportedSchema = 1

    public static let fileName = "manifest.json"

    /// The format of the files, raised when their shape changes in a way an
    /// older reader would misread.
    public var schema: Int
    /// The release, `YYYYMMDDnn`: the UTC day the compiler first saw this
    /// content, and a counter within the day. It only grows, and a higher
    /// number is always newer data, bundled or fetched.
    public var dataVersion: Int
    /// The hash of the whole set, over ``files`` — see ``digest(of:)``.
    public var sha256: String
    /// File name → the SHA-256 of its bytes, lowercase hex.
    public var files: [String: String]

    /// The UTC day in ``dataVersion``: when the compiler first saw this data.
    public var day: Date? {
        let day = dataVersion / 100
        var components = DateComponents(year: day / 10000, month: day / 100 % 100, day: day % 100)
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)
    }

    public init(schema: Int, dataVersion: Int, sha256: String, files: [String: String]) {
        self.schema = schema
        self.dataVersion = dataVersion
        self.sha256 = sha256
        self.files = files
    }

    /// Reads a manifest, refusing one in a format this build does not know
    /// before it tries to read anything else of it.
    init(json: Data) throws(DataSetRejection) {
        struct Header: Decodable { var schema: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: json) else {
            throw .unreadable(file: Self.fileName)
        }
        guard header.schema == Self.supportedSchema else {
            throw .unknownSchema(header.schema)
        }
        guard let manifest = try? JSONDecoder().decode(Self.self, from: json) else {
            throw .unreadable(file: Self.fileName)
        }
        self = manifest
    }

    /// The hash of a set: SHA-256 over one line per file, `<name> <hash>\n`,
    /// sorted by name. The compiler computes the same.
    public static func digest(of files: [String: String]) -> String {
        hex(SHA256.hash(data: Data(files.keys.sorted().map { "\($0) \(files[$0]!)\n" }.joined().utf8)))
    }

    static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The manifest of the set shipped with the app. Cheap next to the set
    /// itself, which is why choosing a set at launch reads this and loads
    /// the bundled files only if they win.
    public static let bundled: DataSetManifest = {
        do {
            guard let url = DataSet.bundledURL(of: fileName) else {
                throw DataSetRejection.missing(file: fileName)
            }
            return try DataSetManifest(json: Data(contentsOf: url))
        } catch {
            preconditionFailure("The bundled data set's manifest is unreadable: \(error)")
        }
    }()
}

/// Why a folder is not a data set this build can run on.
public enum DataSetRejection: Error, Hashable, Sendable {
    /// In a format this build does not read. Not the set's fault.
    case unknownSchema(Int)
    /// The folder's name and the manifest's version disagree.
    case misnamed
    case missing(file: String)
    /// The bytes are not the ones the manifest names.
    case hashMismatch(file: String)
    /// The bytes are the ones named, and still do not decode.
    case unreadable(file: String)

    /// Whether the set itself is broken, so that trying it again at the next
    /// launch would fail the same way. A format this build does not know is
    /// the exception: a newer build reads it.
    public var marksBad: Bool {
        if case .unknownSchema = self { return false }
        return true
    }
}
