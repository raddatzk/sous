import SousKit
import SwiftUI

/// How the cook wants to use a chat model, chosen once in the settings.
///
/// `off` is not stored here: it is `OptimizationChat.off`, as it always was,
/// so the welcome, the step references and every place that already asks
/// whether AI is wanted keep agreeing. What is stored is only the choice
/// between the two ways of asking.
enum AIMode: String, CaseIterable, Identifiable {
    case off
    /// The prompt is copied, the cook's own chat answers, the answer is pasted.
    case copyPaste
    /// Sous asks the cook's provider itself, in a chat of its own.
    case api

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Aus"
        case .copyPaste: "Chat kopieren"
        case .api: "Direkt (API)"
        }
    }

    /// What is in force: "no AI" wins over everything, then the stored choice,
    /// and where nothing was chosen, copy and paste, which is how it was.
    static func effective(chat: OptimizationChat?, stored: AIMode?) -> AIMode {
        if chat == .off { return .off }
        return stored == .api ? .api : .copyPaste
    }
}

extension SousSetting {
    static let aiMode = "aiMode"
}

/// The one control for it, in the settings: off, copy and paste, or the
/// provider; and below it only what the chosen way needs.
struct AIModeSettingsSection: View {
    @AppStorage(SousSetting.optimizationChat, store: .sous)
    private var chat: OptimizationChat?
    @AppStorage(SousSetting.aiMode, store: .sous)
    private var stored: AIMode?
    @State private var connections = AIConnections.shared

    private var mode: AIMode { AIMode.effective(chat: chat, stored: stored) }

    private var selection: Binding<AIMode> {
        Binding(
            get: { mode },
            set: { new in
                switch new {
                case .off:
                    chat = .off
                case .copyPaste, .api:
                    if chat == .off { chat = nil }
                    stored = new
                }
            }
        )
    }

    var body: some View {
        Section {
            Picker("KI", selection: selection) {
                ForEach(AIMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("KI")
        } footer: {
            switch mode {
            case .off:
                Text("Keine KI-Einträge im Rezeptmenü. Zutaten pro Schritt lassen sich von Hand zuordnen.")
            case .copyPaste:
                Text("Sous kopiert den Prompt, du fragst einen Chat, den du schon nutzt, und fügst die Antwort ein.")
            case .api:
                Text("Sous fragt deinen Anbieter selbst, in einem Chat in der App. Dafür braucht es einen eigenen Schlüssel.")
            }
        }
        // What the chosen way needs, in a field of its own below the choice.
        switch mode {
        case .off: EmptyView()
        case .copyPaste: Section { OptimizationChatPicker(includesOff: false) }
        case .api:
            AIConnectionSettingsRow(ai: connections.personal)
            if connections.personal.usable == nil, let household = connections.household.usable {
                Section {
                    Label("Der Haushalt hat \(household.provider.name) eingerichtet. Du nutzt ihn, solange du keinen eigenen Schlüssel hast.", systemImage: "person.2")
                }
            }
        }
    }
}
