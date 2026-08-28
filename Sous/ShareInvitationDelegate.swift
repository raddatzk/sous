import CloudKit
import SousKit
import SwiftUI
import os

/// Says so when the system refuses to register this build for pushes.
///
/// There is no success side to this on purpose — the token is CloudKit's
/// business and the app never touches it. Only the failure is worth a line,
/// and it is worth one because the app has already been shipped once unable
/// to receive a push and unable to say so: the Mac's entitlement is spelled
/// `com.apple.developer.aps-environment`, the file said `aps-environment`,
/// and a signature without it fails this call rather than the build.
private func report(_ failure: Error) {
    Logger(subsystem: "me.raddatz.sous", category: "push")
        .error("Not registered for remote notifications: \(failure.localizedDescription, privacy: .public)")
}

/// The hand-off between the system's delegate callbacks and the app's
/// households.
///
/// A static closure rather than anything grander: the delegates below are
/// instantiated by the system, `CoreDataHouseholds` is owned by `SousApp`,
/// and this is the one line where the two meet. Set once, at the end of the
/// app's init — which runs before any scene connects, so an invitation that
/// launches the app still finds it in place.
enum ShareInvitationHandOff {
    nonisolated(unsafe) static var accept: (@Sendable (CKShare.Metadata) -> Void)?
}

#if os(iOS)
/// The one piece of UIKit lifecycle the app has.
///
/// SwiftUI has no modifier for an accepted CloudKit invitation — the system
/// delivers it to the scene delegate or nowhere. So every scene gets this
/// delegate, whose only job is to pass the metadata along.
final class SousAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SousSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        report(error)
    }
}

final class SousSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// The app was already running when the invitation was tapped.
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        ShareInvitationHandOff.accept?(cloudKitShareMetadata)
    }

    /// The invitation is what launched the app.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            ShareInvitationHandOff.accept?(metadata)
        }
    }
}
#elseif os(macOS)
/// The Mac's counterpart, one level up: AppKit delivers the invitation to
/// the application delegate, not to a scene.
final class SousAppDelegate: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        ShareInvitationHandOff.accept?(metadata)
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        report(error)
    }
}
#endif
