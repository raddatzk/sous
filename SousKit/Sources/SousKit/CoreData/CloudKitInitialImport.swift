import CoreData
import Foundation
import Observation

/// Whether the library this install mirrors from iCloud has arrived yet.
///
/// After a reinstall the stores open empty and CloudKit fills them over the
/// next seconds, or minutes for a large library. Until then every list said
/// "Noch keine Rezepte — lege dein erstes Rezept an", which is the one thing
/// that is not true, and the welcome greeted a cook whose library was on its
/// way.
///
/// So the screens ask this instead. It listens to the container's own import
/// events: the first import that ends well for every mirrored store settles
/// it, and that is remembered in the app group's defaults, which leave with
/// the app — a reinstall waits again, an ordinary launch never does.
///
/// A failed import, or none starting at all, settles it for this launch only:
/// offline or without an iCloud account, a spinner that never stops is worse
/// than an empty list. The next launch waits again, and an import that
/// succeeds later in this one is still remembered.
///
/// No progress beyond "waiting": the events say that an import runs, not how
/// much of the library it has brought.
@MainActor
@Observable
public final class CloudKitInitialImport {
    /// Whether the screens should still expect the library to arrive.
    public private(set) var isWaiting: Bool

    private let defaults: UserDefaults
    private static let defaultsKey = "didFinishInitialCloudKitImport"
    @ObservationIgnored private var tracker: Tracker
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var quietTimeout: Task<Void, Never>?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    /// A failure followed by a late success must not run the reload twice.
    @ObservationIgnored private var isSettling = false
    /// Run before the screens are told the import is done, so the reload has
    /// landed by then — otherwise the empty state flashes for the second the
    /// remote-change throttle waits.
    @ObservationIgnored private var beforeSettling: (@MainActor () async -> Void)?

    /// - Parameters:
    ///   - container: the store whose import is waited for. Nothing is
    ///     waited for where it does not mirror.
    ///   - quietPeriod: how long to wait for an import to *start* before
    ///     giving up for this launch. Once one has started, its end decides.
    public init(
        container: NSPersistentContainer,
        defaults: UserDefaults = .sous,
        quietPeriod: Duration = .seconds(30)
    ) {
        self.defaults = defaults
        let stores = Set(container.persistentStoreCoordinator.persistentStores.compactMap(\.identifier))
        tracker = Tracker(storeIdentifiers: stores)
        isWaiting = container is NSPersistentCloudKitContainer
            && SousPersistentContainer.isConfiguredForCloudKit
            && !defaults.bool(forKey: Self.defaultsKey)
        guard isWaiting else { return }

        // Registered here, synchronously, rather than in a task: the setup
        // and the first import begin as soon as the stores are loaded, and a
        // listener that starts a run loop later can miss the one event that
        // matters.
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { [weak self] note in
            guard let event = note.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            let report = Tracker.Event(
                kind: Tracker.Kind(event.type),
                storeIdentifier: event.storeIdentifier,
                ended: event.endDate != nil,
                succeeded: event.succeeded
            )
            Task { @MainActor in self?.handle(report) }
        }

        quietTimeout = Task { [weak self] in
            try? await Task.sleep(for: quietPeriod)
            guard !Task.isCancelled else { return }
            self?.giveUpIfNothingStarted()
        }
    }

    /// Sets what has to happen before the screens stop waiting.
    public func onSettling(_ work: @escaping @MainActor () async -> Void) {
        beforeSettling = work
    }

    /// Returns once the screens no longer wait — at once where they never did.
    public func waitUntilSettled() async {
        guard isWaiting else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func handle(_ event: Tracker.Event) {
        switch tracker.record(event) {
        case .waiting:
            break
        case .arrived:
            defaults.set(true, forKey: Self.defaultsKey)
            stopListening()
            settle()
        case .failed:
            // Not remembered, and still listening: a retry that succeeds in
            // this launch should spare the next one the wait.
            settle()
        }
    }

    private func giveUpIfNothingStarted() {
        guard !tracker.sawImportStart else { return }
        settle()
    }

    private func settle() {
        quietTimeout?.cancel()
        guard isWaiting, !isSettling else { return }
        isSettling = true
        Task {
            await beforeSettling?()
            isWaiting = false
            let waiting = waiters
            waiters = []
            for waiter in waiting { waiter.resume() }
        }
    }

    private func stopListening() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// The bookkeeping, apart from notifications and time so it can be
    /// tested with plain values.
    struct Tracker {
        enum Kind: Equatable {
            case setup, `import`, export, other

            init(_ type: NSPersistentCloudKitContainer.EventType) {
                self = switch type {
                case .setup: .setup
                case .import: .import
                case .export: .export
                @unknown default: .other
                }
            }
        }

        struct Event {
            var kind: Kind
            var storeIdentifier: String
            var ended: Bool
            var succeeded: Bool
        }

        enum Outcome: Equatable {
            case waiting
            /// Every mirrored store has finished an import.
            case arrived
            /// Setup or an import failed; nothing more is coming soon.
            case failed
        }

        /// Stores that have not finished an import yet. Both of them, the
        /// private and the shared: a joined household arrives through the
        /// second.
        private var pending: Set<String>
        private(set) var sawImportStart = false

        init(storeIdentifiers: Set<String>) {
            pending = storeIdentifiers
        }

        mutating func record(_ event: Event) -> Outcome {
            switch event.kind {
            case .import:
                guard event.ended else {
                    sawImportStart = true
                    return .waiting
                }
                guard event.succeeded else { return .failed }
                pending.remove(event.storeIdentifier)
                return pending.isEmpty ? .arrived : .waiting
            case .setup:
                return event.ended && !event.succeeded ? .failed : .waiting
            case .export, .other:
                return .waiting
            }
        }
    }
}
