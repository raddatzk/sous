import Foundation
import Testing
@testable import SousKit

/// Which data set this device last ran against — what decides whether the
/// launch rebuilds the search index (`SousApp.reindexAfterDataChange`).
///
/// Since phase 6b nothing is reconciled after a data update: the catalog
/// answers, and a vanished row is a data fix, not a question for the cook.
@Suite("The data marker")
struct BundledDataMarkerTests {
    @Test("The marker notices a data change once, and says nothing on the next start")
    func markerReportsAChangeOnlyOnce() throws {
        let suiteName = "sous.tests.marker.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let marker = BundledDataMarker(defaults: defaults)

        let first = BundledDataStamp(
            fingerprint: "aaa", datasetVersion: "BLS 4.0", seenAt: Date(timeIntervalSince1970: 1)
        )
        // A device that has never recorded one has never indexed against
        // this data — and may carry recipes synced from another release.
        #expect(marker.hasChanged(from: first))

        marker.record(first)
        #expect(!marker.hasChanged(from: first))
        #expect(marker.lastSeen?.datasetVersion == "BLS 4.0")
        #expect(marker.lastSeen?.seenAt == Date(timeIntervalSince1970: 1))

        // A new bundle moves the fingerprint whether or not the version
        // string moved with it, which is why the hash is what is compared.
        let second = BundledDataStamp(
            fingerprint: "bbb", datasetVersion: "BLS 4.0", seenAt: Date(timeIntervalSince1970: 2)
        )
        #expect(marker.hasChanged(from: second))
    }

    @Test("What the app currently ships is a stamp with both halves filled in")
    func theCurrentStampIsReadable() {
        let stamp = BundledDataMarker.current()
        // The whole point of the marker: this used to be a `static let` with
        // the lifetime of the process and no way to read it back.
        #expect(!stamp.fingerprint.isEmpty)
        #expect(stamp.datasetVersion == BLSCatalog.bundled.source.datasetVersion)
    }
}
