import CloudKit
import Foundation
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

@Suite("What a CloudKit failure is written out as")
struct CloudKitFailureDetailTests {
    @Test("A partial failure names each refused record and only counts the rest")
    func partialFailure() {
        let zone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.share.X", ownerName: CKCurrentUserDefaultName)
        let refused = CKRecord.ID(recordName: "A", zoneID: zone)
        let follower = CKRecord.ID(recordName: "B", zoneID: zone)
        let error = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: [
                refused: NSError(domain: CKErrorDomain, code: CKError.Code.invalidArguments.rawValue, userInfo: [
                    "ServerErrorDescription": "Cannot create or modify field 'CD_x'",
                ]),
                follower: NSError(domain: CKErrorDomain, code: CKError.Code.batchRequestFailed.rawValue),
            ] as [AnyHashable: any Error],
        ])

        let lines = CloudKitEventLog.details(of: error)

        #expect(lines.count == 2)
        #expect(lines.contains { $0.hasPrefix("record A in com.apple.coredata.cloudkit.share.X: CKErrorDomain 12 — server: Cannot create or modify field 'CD_x'") })
        #expect(lines.contains("1 more rejected only because the batch failed"))
    }

    @Test("An error wrapped by Core Data is followed to its CloudKit cause")
    func underlying() {
        let cause = NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue)
        let error = NSError(domain: NSCocoaErrorDomain, code: 134410, userInfo: [NSUnderlyingErrorKey: cause])

        let lines = CloudKitEventLog.details(of: error)

        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("CKErrorDomain 25"))
    }
}
