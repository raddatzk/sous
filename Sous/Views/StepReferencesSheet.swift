import SousKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Which ingredients each step takes, and which written amounts belong to
/// which line: asked of a chat model the cook already uses — copy the
/// prompt, paste it into the chat the cook picked, paste the answer back — and
/// corrected, or assigned from scratch, by hand. Sous never talks to the
/// model itself — see ``StepReferences``.
struct StepReferencesSheet: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    @AppStorage(SousSetting.stepReferencesChat, store: .sous)
    private var chat: StepReferencesChat?
    @State private var didCopy = false
    /// What is being edited: the stored references while they still fit the
    /// recipe, a pasted answer, or an empty start by hand. `nil` until one
    /// of those exists.
    @State private var draft: StepReferences?
    @State private var reading: StepReferencesPrompt.Reading?
    @State private var failure: String?
    /// What the draft started as, so a swipe can tell whether it would lose
    /// anything.
    private let initialDraft: StepReferences?

    private let formatter = QuantityFormatter(locale: .sous)

    init(recipe: Recipe) {
        self.recipe = recipe
        let current = recipe.stepReferences.flatMap { $0.isCurrent(for: recipe) ? $0 : nil }
        _draft = State(initialValue: current)
        initialDraft = current
    }

    private var stored: StepReferences? { recipe.stepReferences }
    private var lines: [RecipeIngredient] { recipe.ingredients }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if chat != .off {
                    askSection
                    pasteSection
                    if let reading {
                        readingSections(reading)
                    }
                }
                if draft == nil {
                    Section {
                        Button("Von Hand zuordnen", systemImage: "hand.point.up.left") {
                            draft = .empty(for: recipe)
                        }
                    } footer: {
                        if chat == .off {
                            Text("Schritt für Schritt selbst festlegen, was jeder Schritt braucht. KI ist in den Einstellungen ausgeschaltet.")
                        } else {
                            Text("Ohne Chat: Schritt für Schritt selbst festlegen, was jeder Schritt braucht.")
                        }
                    }
                } else {
                    editor
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Zutaten pro Schritt")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        guard let draft else { return }
                        Task {
                            await library.setStepReferences(draft, for: recipe)
                            dismiss()
                        }
                    }
                    .disabled(draft == nil || draft == stored)
                }
            }
        }
        // Swiping away would drop the draft without a word; once there is
        // something to lose, only the two buttons close it.
        .interactiveDismissDisabled(draft != initialDraft)
        .sousSheetSizing(.page)
    }

    // MARK: - Asking

    @ViewBuilder
    private var statusSection: some View {
        if let stored {
            Section {
                if !stored.isCurrent(for: recipe) {
                    Label("Das Rezept wurde seitdem geändert — die gespeicherte Zuordnung passt nicht mehr.", systemImage: "exclamationmark.triangle")
                }
                Button("Zuordnung entfernen", role: .destructive) {
                    Task {
                        await library.setStepReferences(nil, for: recipe)
                        dismiss()
                    }
                }
            }
        }
    }

    private var askSection: some View {
        Section {
            Button(didCopy ? "Prompt kopiert" : "Prompt kopieren", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                copy(StepReferencesPrompt.prompt(for: recipe))
                didCopy = true
            }
            if let chat {
                if let url = chat.url {
                    Link(destination: url) {
                        Label("\(chat.title) öffnen", systemImage: "arrow.up.forward.app")
                    }
                }
            } else {
                StepReferencesChatPicker()
            }
        } header: {
            Text("Chat fragen")
        } footer: {
            Text("Den kopierten Text in einen neuen Chat einfügen und abschicken. Welcher Chat, lässt sich in den Einstellungen ändern.")
        }
    }

    private var pasteSection: some View {
        Section {
            PasteButton(payloadType: String.self) { strings in
                let pasted = strings.joined(separator: "\n")
                Task { @MainActor in read(pasted) }
            }
            if let failure {
                Label(failure, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Antwort einfügen")
        } footer: {
            Text("Die Antwort des Chats kopieren — am einfachsten über den Kopieren-Knopf am Codeblock. Sie ersetzt, was unten steht.")
        }
    }

    @ViewBuilder
    private func readingSections(_ reading: StepReferencesPrompt.Reading) -> some View {
        if !reading.notes.isEmpty {
            Section {
                ForEach(reading.notes, id: \.self) { note in
                    Label(note, systemImage: "text.badge.checkmark")
                }
            } header: {
                Text("Passt im Rezept nicht zusammen")
            } footer: {
                Text("Das hat der Chat bemerkt. Korrigieren lässt es sich im Rezept selbst — danach neu fragen.")
            }
        }
        if !reading.warnings.isEmpty {
            Section("Hinweise") {
                ForEach(reading.warnings, id: \.self) { warning in
                    Label(text(for: warning), systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    // MARK: - Editing

    /// One section per step: the step as cook mode will show it, the written
    /// amounts with the line each belongs to, and the chips — every one of
    /// them changeable.
    @ViewBuilder
    private var editor: some View {
        if let draft {
            let rendition = recipeShowing(draft).stepRendition(formatter: formatter)
            ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { stepIndex, step in
                let references = draft.steps.indices.contains(stepIndex) ? draft.steps[stepIndex] : []
                Section {
                    Text(attributedText(for: rendition.segments(for: step)))
                        .font(.callout)

                    ForEach(Array(references.enumerated()), id: \.offset) { index, reference in
                        switch reference.kind {
                        case .amount:
                            amountRow(reference, at: index, inStepAt: stepIndex)
                        case .mention:
                            if let line = reference.line {
                                chipRow(line: line, amount: reference.amount, inStepAt: stepIndex)
                            }
                        }
                    }

                    let taken = Set(references.filter { $0.kind == .mention }.compactMap(\.line))
                    Menu {
                        ForEach(Array(lines.enumerated()), id: \.offset) { lineIndex, line in
                            if !taken.contains(lineIndex + 1) {
                                Button(label(for: line)) {
                                    self.draft?.setChip(line: lineIndex + 1, amount: nil, inStepAt: stepIndex)
                                }
                            }
                        }
                    } label: {
                        Label("Zutat hinzufügen", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Schritt \(stepIndex + 1)")
                }
            }
        }
    }

    /// A written amount: the line it scales with, changeable, or let go so
    /// the text stays as written.
    private func amountRow(_ reference: StepReferences.Reference, at index: Int, inStepAt stepIndex: Int) -> some View {
        HStack {
            Text(reference.text)
                .foregroundStyle(Color.sousAccent)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)
            Picker("Zeile", selection: Binding(
                get: { reference.line ?? 0 },
                set: { draft?.setLine($0 == 0 ? nil : $0, forReferenceAt: index, inStepAt: stepIndex) }
            )) {
                Text("Keine Zutat").tag(0)
                // Name and group only — the whole line would be cut off in
                // the row, and the amount is already written in the text.
                ForEach(Array(lines.enumerated()), id: \.offset) { lineIndex, line in
                    Text(line.group.map { "\(line.name) · \($0)" } ?? line.name).tag(lineIndex + 1)
                }
            }
            .labelsHidden()
            Spacer(minLength: 0)
            Button("Zuordnung lösen", systemImage: "xmark.circle") {
                draft?.removeReference(at: index, inStepAt: stepIndex)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    /// A chip: the line, how much of it the step takes, and a way to drop it.
    private func chipRow(line: Int, amount: String?, inStepAt stepIndex: Int) -> some View {
        let ingredient = lines.indices.contains(line - 1) ? lines[line - 1] : nil
        let text = amount ?? ""
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ingredient?.name ?? "Zeile \(line)")
                    .lineLimit(2)
                // The whole line, so the cook can see what the step's share
                // is a share of.
                if let ingredient {
                    Text(label(for: ingredient))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            TextField("Menge", text: Binding(
                get: { text },
                set: { draft?.setChip(line: line, amount: $0, inStepAt: stepIndex) }
            ))
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 110)
            .foregroundStyle(text.isEmpty || StepReferencesPrompt.readsAsAmount(text) ? Color.primary : Color.red)
            Button("Entfernen", systemImage: "xmark.circle") {
                draft?.removeChip(line: line, fromStepAt: stepIndex)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    /// A line as the cook knows it from the list, with its group where the
    /// list has several — "200 g Butter (Füllung)".
    private func label(for line: RecipeIngredient) -> String {
        let text = formatter.string(for: line)
        guard let group = line.group else { return text }
        return "\(text) (\(group))"
    }

    private func recipeShowing(_ references: StepReferences) -> Recipe {
        var copy = recipe
        copy.stepReferences = references
        return copy
    }

    /// Steps carry the same inline markdown as everywhere else — a bold
    /// phase name reads bold here too — and the amounts wear the accent.
    private func attributedText(for segments: [StepAmountSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let string):
                result += (try? AttributedString(
                    markdown: string,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(string)
            case .amount(let string):
                var run = AttributedString(string)
                run.foregroundColor = .sousAccent
                result += run
            }
        }
        return result
    }

    private func read(_ pasted: String) {
        switch StepReferencesPrompt.read(pasted, for: recipe) {
        case .success(let value):
            reading = value
            draft = value.references
            failure = nil
        case .failure(let error):
            reading = nil
            failure = error.localizedDescription
        }
    }

    private func text(for warning: StepReferencesPrompt.Warning) -> String {
        func name(_ line: Int) -> String {
            lines.indices.contains(line - 1) ? lines[line - 1].name : "Zeile \(line)"
        }
        switch warning {
        case .notInStep(let step, let text):
            return "Schritt \(step): Die Menge „\(text)“ steht so nicht im Text und wird nicht umgerechnet."
        case .unreadableAmount(let step, let text):
            return "Schritt \(step): „\(text)“ ist keine lesbare Menge und bleibt, wie sie ist."
        case .overbooked(let line, let percent):
            return "\(name(line)): Die im Text geschriebenen Mengen ergeben zusammen \(percent) % der Zeile."
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// The chat the cook asks for "Zutaten pro Schritt" — chosen once, in the
/// welcome or the settings, so the sheet offers one way out instead of a
/// list of apps somebody else uses.
///
/// Any of them reads the same prompt; the choice only decides which one the
/// sheet opens. The web addresses are universal links, so an installed app
/// opens instead of the browser. "Anderer Chat" is for everything not listed
/// — the sheet then only copies.
///
/// `off` is for cooks who want no AI in the app at all: the sheet then
/// neither copies a prompt nor takes an answer, and assigning by hand is
/// what is left. One setting rather than a toggle beside the choice, so
/// "which chat" and "whether a chat" cannot contradict each other.
enum StepReferencesChat: String, CaseIterable, Identifiable {
    case chatGPT = "chatgpt"
    case claude
    case gemini
    case leChat = "lechat"
    case copilot
    case other
    case off

    /// The chats, without the way out of all of them.
    static let chats = allCases.filter { $0 != .off }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .leChat: "Le Chat"
        case .copilot: "Copilot"
        case .other: "Anderer Chat"
        case .off: "Keine KI verwenden"
        }
    }

    /// Where a new chat starts, or `nil` for one Sous does not know.
    var url: URL? {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/")
        case .claude: URL(string: "https://claude.ai/new")
        case .gemini: URL(string: "https://gemini.google.com/app")
        case .leChat: URL(string: "https://chat.mistral.ai/chat")
        case .copilot: URL(string: "https://copilot.microsoft.com/")
        case .other, .off: nil
        }
    }
}

extension SousSetting {
    static let stepReferencesChat = "stepReferencesChat"
}

/// The choice of chat, the same control wherever it is offered. Unset until
/// the cook picks one — a default would quietly send everybody to the same
/// company.
struct StepReferencesChatPicker: View {
    @AppStorage(SousSetting.stepReferencesChat, store: .sous)
    private var chat: StepReferencesChat?

    var body: some View {
        Picker("Chat", selection: $chat) {
            if chat == nil {
                Text("Nicht gewählt").tag(StepReferencesChat?.none)
            }
            ForEach(StepReferencesChat.chats) { option in
                Text(option.title).tag(Optional(option))
            }
            Divider()
            Text(StepReferencesChat.off.title).tag(Optional(StepReferencesChat.off))
        }
    }
}
