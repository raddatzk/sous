import Foundation

/// One source the shipped data is drawn from, as it asks to be named.
///
/// CC BY 4.0 asks for the source, its licence, and whether it was changed.
/// These travel with the data set itself (`sources.json`, compiled from
/// `Community/sources/<id>.yaml`), so a data set published apart from an app release
/// still says where it comes from — the sources screen reads them rather than
/// a string compiled into the app.
///
/// Every source is the same record, the BLS as much as any other: the register
/// in `Community/sources/` holds one per body the values are drawn from, and every
/// row of `nutrition.json` names its source by `id`.
public struct DataSource: Codable, Hashable, Sendable, Identifiable {
    /// `bls` for the Bundeslebensmittelschlüssel, `ciqual-2020` and the like
    /// for the others.
    public var id: String
    /// The section heading the sources screen gives it.
    public var title: String
    /// Who publishes it.
    public var publisher: String
    /// Where it can be looked up.
    public var url: URL?
    /// How the source is cited in front of a row: "Ciqual 2020 (Anses)".
    public var version: String
    public var release: String
    /// When the tables were downloaded, "2026-10-05". Absent for a source
    /// written by hand (nutrition labels), where each row has its own date.
    public var retrieved: String?
    public var license: String
    public var licenseURL: URL
    public var attribution: String
    public var changeNote: String
}

public enum DataSources {
    private struct File: Decodable {
        var sources: [DataSource]
    }

    /// `sources.json`, in the order the page shows them: the BLS first, then
    /// by how many shipped rows each source gives.
    static func decode(_ json: Data) throws -> [DataSource] {
        try JSONDecoder().decode(File.self, from: json).sources
    }

    /// The sources of the data set this process runs on — the one the
    /// sources screen names, which is not always the one the app shipped.
    public static var current: [DataSource] { DataSet.current.sources }

    /// The sources of the data shipped with the app.
    public static var bundled: [DataSource] { DataSet.bundled.sources }
}
