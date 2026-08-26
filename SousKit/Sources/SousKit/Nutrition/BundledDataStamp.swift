import Foundation

/// Which shipped data this device last ran against.
///
/// The concept's §7 asks the app to reconcile "after an update". Nothing in
/// the app could tell that an update had happened: the bundled files are
/// hashed into every cached figure, but only as a `static let` with the
/// lifetime of the process — a fingerprint nobody could read back and compare
/// against the last launch. This is that missing memory, and nothing more.
public struct BundledDataStamp: Equatable, Hashable, Sendable {
    /// The hash over the shipped catalog files — the thing that actually
    /// changes when a release swaps the bundle, whether or not the version
    /// string moved with it.
    public var fingerprint: String
    /// What that data calls itself: "BLS 4.0". Kept beside the hash because
    /// it is the half a person can read, and the sources screen prints it.
    public var datasetVersion: String
    /// When this device first ran against this data — the "zuletzt
    /// aktualisiert" of the sources screen. Deliberately *not* refreshed on
    /// an unchanged launch, or it would say "today" forever.
    public var seenAt: Date

    public init(fingerprint: String, datasetVersion: String, seenAt: Date) {
        self.fingerprint = fingerprint
        self.datasetVersion = datasetVersion
        self.seenAt = seenAt
    }
}

/// Remembers the last ``BundledDataStamp`` across launches, so a run can ask
/// whether the shipped data changed under it.
///
/// **Device state, not user content** — hence `UserDefaults` rather than a
/// SwiftData row. Every device carries its own copy of the bundle and updates
/// it on its own schedule, so a synchronized row would let a phone that has
/// already run the reconciliation suppress it on a Mac that has not yet seen
/// the new data at all. The vocabulary those two devices share *is* user
/// content and does sync; which release each of them has read is not.
///
/// The suite is the app group's, so the share extension sees the same marker
/// — it runs no reconciliation itself, but it must not be able to write a
/// second, disagreeing one.
public struct BundledDataMarker: Sendable {
    private enum Key {
        static let fingerprint = "bundledData.fingerprint"
        static let datasetVersion = "bundledData.datasetVersion"
        static let seenAt = "bundledData.seenAt"
    }

    /// `UserDefaults` is thread-safe by contract, which the type system does
    /// not know — the same reason the shared suite is declared the way it is.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Injectable so a test can have a marker of its own; the app uses the
    /// shared suite.
    public init(defaults: UserDefaults = .sous) {
        self.defaults = defaults
    }

    /// What the app is shipping right now, stamped as of `date`.
    public static func current(at date: Date = .nowInSyncPrecision) -> BundledDataStamp {
        BundledDataStamp(
            fingerprint: RecipeContentHash.bundledDataFingerprint,
            datasetVersion: BLSCatalog.bundled.source.datasetVersion,
            seenAt: date
        )
    }

    /// The stamp of the last run, or `nil` on a device that has never
    /// recorded one — a fresh install, or the launch that introduces this.
    public var lastSeen: BundledDataStamp? {
        guard let fingerprint = defaults.string(forKey: Key.fingerprint), !fingerprint.isEmpty
        else { return nil }
        return BundledDataStamp(
            fingerprint: fingerprint,
            datasetVersion: defaults.string(forKey: Key.datasetVersion) ?? "",
            seenAt: Date(timeIntervalSince1970: defaults.double(forKey: Key.seenAt))
        )
    }

    /// Whether `stamp` is data this device has not run against yet.
    ///
    /// A device with no marker counts as changed: it has never reconciled,
    /// and the entries it carries may have arrived by sync from a device that
    /// was on a different release.
    public func hasChanged(from stamp: BundledDataStamp = BundledDataMarker.current()) -> Bool {
        lastSeen?.fingerprint != stamp.fingerprint
    }

    /// Writes down what was just run against. Called only after the
    /// reconciliation actually ran, so a crash in between leaves the work to
    /// the next launch rather than skipping it forever.
    public func record(_ stamp: BundledDataStamp = BundledDataMarker.current()) {
        defaults.set(stamp.fingerprint, forKey: Key.fingerprint)
        defaults.set(stamp.datasetVersion, forKey: Key.datasetVersion)
        defaults.set(stamp.seenAt.timeIntervalSince1970, forKey: Key.seenAt)
    }
}
