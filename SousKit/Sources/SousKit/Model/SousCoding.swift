import Foundation

/// The canonical serialization of an aggregate.
///
/// The format is defined here rather than left to the caller, because it is
/// what the sync layer encrypts and what a second platform has to read back.
/// Keys are sorted so that equal content produces equal bytes.
public enum SousCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.millisecondsSince1970)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let milliseconds = try decoder.singleValueContainer().decode(Int64.self)
            return Date(millisecondsSince1970: milliseconds)
        }
        return decoder
    }
}

extension Date {
    /// Milliseconds since the Unix epoch — the wire representation of a
    /// timestamp. An integer rather than a formatted string, so that it is
    /// exact, idempotent, and trivially readable from another platform.
    public var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    public init(millisecondsSince1970 milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// The value as it will exist after a serialization round trip.
    ///
    /// Timestamps are stored at this precision so that a comparison never
    /// changes meaning after a save — sync resolves conflicts by `updatedAt`,
    /// and an equality that only holds before persisting is a bug in waiting.
    public var syncPrecision: Date {
        Date(millisecondsSince1970: millisecondsSince1970)
    }

    /// The current time at the precision the sync format carries.
    public static var nowInSyncPrecision: Date { Date().syncPrecision }
}
