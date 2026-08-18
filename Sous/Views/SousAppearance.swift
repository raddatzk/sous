import SousKit
import SwiftData
import SwiftUI

/// Whether the app follows the system, or is pinned to one scheme.
///
/// Cooking happens at both ends of the day, and the phone's own switch is
/// often on a schedule that has nothing to do with the kitchen — so the app
/// lets the cook decide, and remembers it for the share extension too.
enum SousAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// `nil` hands the decision back to the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension UserDefaults {
    /// Settings the app and its share extension share, so a recipe checked in
    /// the share sheet looks like the app the cook just came from.
    /// `UserDefaults` is thread-safe by contract, which the type system does
    /// not know; the suite is opened once and never replaced.
    nonisolated(unsafe) public static let sous =
        UserDefaults(suiteName: ModelContainer.appGroup) ?? .standard
}

/// The keys behind the settings, in one place so the app, the extension and
/// cook mode cannot drift apart on spelling.
enum SousSetting {
    static let appearance = "appearance"
}

extension View {
    /// Puts a whole window — or a share sheet — into the chosen scheme.
    func sousAppearance() -> some View {
        modifier(SousAppearanceModifier())
    }
}

private struct SousAppearanceModifier: ViewModifier {
    @AppStorage(SousSetting.appearance, store: .sous)
    private var appearance: SousAppearance = .system

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}
