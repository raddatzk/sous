import Foundation

extension UserDefaults {
    /// Settings the app and its share extension share, so a recipe checked in
    /// the share sheet looks like the app the cook just came from.
    /// `UserDefaults` is thread-safe by contract, which the type system does
    /// not know; the suite is opened once and never replaced.
    ///
    /// It lives here rather than beside the appearance setting that used to
    /// own it because the suite is not a view's business: it is the app
    /// group's, which is this module's — and since phase 6 the kit itself
    /// writes to it (see ``BundledDataMarker``).
    nonisolated(unsafe) public static let sous = SousAppGroup.defaults
}
