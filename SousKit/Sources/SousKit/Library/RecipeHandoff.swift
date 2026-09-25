import Foundation

/// The recipe a device is showing, as Handoff carries it to the next one.
///
/// Only the id travels, and the household it is read in. The recipe itself is already on the other device —
/// CloudKit put it there — and a title or a text copied into the activity
/// would be a second, staler version of what that device can read for
/// itself.
public enum RecipeHandoff {
    /// Declared under `NSUserActivityTypes` in `project.yml` as well; an
    /// activity whose type the app does not list is never offered.
    public static let activityType = "me.raddatz.sous.recipe"

    static let recipeIDKey = "recipeID"
    static let householdIDKey = "householdID"

    /// With the household the recipe is read in, so the receiving device
    /// can find it when it is showing a different one — see
    /// `RecipeLink.url(for:household:)`.
    public static func userInfo(for id: UUID, household: UUID? = nil) -> [String: String] {
        var info = [recipeIDKey: id.uuidString]
        info[householdIDKey] = household?.uuidString
        return info
    }

    /// The recipe an incoming activity names, or `nil` if it names none.
    public static func recipeID(from userInfo: [AnyHashable: Any]?) -> UUID? {
        (userInfo?[recipeIDKey] as? String).flatMap(UUID.init(uuidString:))
    }

    /// The household the sending device was reading the recipe in, or `nil`
    /// for an activity from a build that did not say.
    public static func householdID(from userInfo: [AnyHashable: Any]?) -> UUID? {
        (userInfo?[householdIDKey] as? String).flatMap(UUID.init(uuidString:))
    }
}
