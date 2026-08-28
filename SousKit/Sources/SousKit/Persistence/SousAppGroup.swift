import Foundation

/// The container the app and its extensions share their files and settings
/// in — where this build has one at all.
///
/// On iOS it always does: the share extension writes recipes the app has to
/// find, and the widgets read what the app wrote. On macOS it deliberately
/// does not. A sandboxed Mac app may only claim a group whose identifier is
/// prefixed with the team identifier, which is a *different* group from the
/// one iOS uses, and both extensions are iOS-only — so the Mac would be
/// sharing a directory with nobody. See `Sous-macOS.entitlements`.
///
/// That has to be stated here rather than derived from the file system,
/// because `containerURL(forSecurityApplicationGroupIdentifier:)` does not
/// answer the question on macOS: it hands back
/// `~/Library/Group Containers/<id>` whether the app is entitled to that
/// directory or not, and the sandbox then denies every read of it. Believing
/// that URL is what killed the first Mac build on launch — both stores opened
/// onto a path they were not allowed to touch, SQLite returned
/// `SQLITE_AUTH`, and the app stopped before its first window.
public enum SousAppGroup {
    /// The iOS group. Named even where it is unusable, because the share
    /// extension's Info.plist and the entitlements both spell it out and a
    /// second spelling would be a second thing to keep in step.
    public static let identifier = "group.me.raddatz.sous"

    /// The shared directory, or `nil` where this build has none — in which
    /// case the caller keeps its files in the app's own container.
    public static var url: URL? {
        #if os(macOS)
        nil
        #else
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        #endif
    }

    /// The defaults the app and its extensions share, or the app's own where
    /// there is nobody to share with.
    ///
    /// Same denial as the stores, only silent: writing to a suite the sandbox
    /// refuses loses the setting without an error anybody sees, so the Mac
    /// has to be given `.standard` rather than left to find out.
    public static var defaults: UserDefaults {
        guard url != nil, let shared = UserDefaults(suiteName: identifier) else { return .standard }
        return shared
    }
}
