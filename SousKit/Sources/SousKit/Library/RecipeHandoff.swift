import Foundation

/// The recipe a device is showing, as Handoff carries it to the next one.
///
/// Only the id travels. The recipe itself is already on the other device —
/// CloudKit put it there — and a title or a text copied into the activity
/// would be a second, staler version of what that device can read for
/// itself.
public enum RecipeHandoff {
    /// Declared under `NSUserActivityTypes` in `project.yml` as well; an
    /// activity whose type the app does not list is never offered.
    public static let activityType = "me.raddatz.sous.recipe"

    static let recipeIDKey = "recipeID"

    public static func userInfo(for id: UUID) -> [String: String] {
        [recipeIDKey: id.uuidString]
    }

    /// The recipe an incoming activity names, or `nil` if it names none.
    public static func recipeID(from userInfo: [AnyHashable: Any]?) -> UUID? {
        (userInfo?[recipeIDKey] as? String).flatMap(UUID.init(uuidString:))
    }
}
