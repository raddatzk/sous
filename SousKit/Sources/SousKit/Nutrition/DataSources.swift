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

    /// The sources of the data shipped with the app, in the order the
    /// screen shows them: the BLS first.
    public static let bundled: [DataSource] = {
        guard let url = Bundle.module.url(forResource: "sources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            assertionFailure("The bundled sources are missing or unreadable")
            return []
        }
        return file.sources
    }()
}
