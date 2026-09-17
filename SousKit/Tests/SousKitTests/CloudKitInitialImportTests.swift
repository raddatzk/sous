import Testing
@testable import SousKit

@Suite("Waiting for the first CloudKit import")
struct CloudKitInitialImportTests {
    typealias Tracker = CloudKitInitialImport.Tracker

    private func event(
        _ kind: Tracker.Kind,
        store: String = "private",
        ended: Bool = true,
        succeeded: Bool = true
    ) -> Tracker.Event {
        Tracker.Event(kind: kind, storeIdentifier: store, ended: ended, succeeded: succeeded)
    }

    @Test func arrivesOnlyOnceEveryStoreHasImported() {
        var tracker = Tracker(storeIdentifiers: ["private", "shared"])
        #expect(tracker.record(event(.setup)) == .waiting)
        #expect(tracker.record(event(.import, store: "private", ended: false)) == .waiting)
        #expect(tracker.sawImportStart)
        #expect(tracker.record(event(.import, store: "private")) == .waiting)
        #expect(tracker.record(event(.import, store: "shared")) == .arrived)
    }

    @Test func aFailedImportStopsTheWait() {
        var tracker = Tracker(storeIdentifiers: ["private"])
        #expect(tracker.record(event(.import, succeeded: false)) == .failed)
    }

    @Test func aFailedSetupStopsTheWait() {
        var tracker = Tracker(storeIdentifiers: ["private"])
        #expect(tracker.record(event(.setup, ended: false)) == .waiting)
        #expect(tracker.record(event(.setup, succeeded: false)) == .failed)
    }

    @Test func exportsSayNothingAboutTheLibraryArriving() {
        var tracker = Tracker(storeIdentifiers: ["private"])
        #expect(tracker.record(event(.export)) == .waiting)
        #expect(tracker.record(event(.export, succeeded: false)) == .waiting)
        #expect(!tracker.sawImportStart)
    }

    @Test func aStartedEventIsNotAFinishedOne() {
        var tracker = Tracker(storeIdentifiers: ["private"])
        #expect(tracker.record(event(.import, ended: false, succeeded: false)) == .waiting)
    }
}
