import Foundation

/// One source the shipped data is drawn from, as it asks to be named.
///
/// CC BY 4.0 asks for the source, its licence, and whether it was changed.
/// These travel with the data set itself (`sources.json`, compiled from
/// `Data/sources.yaml`), so a data set published apart from an app release
/// still says where it comes from — the sources screen reads them rather than
/// a string compiled into the app.
public struct DataSource: Codable, Hashable, Sendable, Identifiable {
    /// `bls` for the Bundeslebensmittelschlüssel, `supplements` for the rows
    /// it does not have.
    public var id: String
    /// The section heading the sources screen gives it.
    public var title: String
    public var datasetVersion: String
    public var release: String
    public var license: String
    public var licenseURL: URL
    public var attribution: String
    public var changeNote: String
}

public enum DataSources {
    private struct File: Decodable {
        var sources: [DataSource]
    }

    /// `sources.json`, in the order the screen shows them: the BLS first.
    static func decode(_ json: Data) throws -> [DataSource] {
        try JSONDecoder().decode(File.self, from: json).sources
    }

    /// The sources of the data set this process runs on — the one the
    /// sources screen names, which is not always the one the app shipped.
    public static var current: [DataSource] { DataSet.current.sources }

    /// The sources of the data shipped with the app.
    public static var bundled: [DataSource] { DataSet.bundled.sources }
}
