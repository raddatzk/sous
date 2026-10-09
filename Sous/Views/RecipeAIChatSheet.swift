import SousKit
import SwiftUI

/// "Mit KI bearbeiten" with a provider of the cook's own: a chat in the
/// classic shape — the conversation above, the field below — in which the
/// model explains what it changed and Sous shows the recipe itself, as a card
/// that says what is new and what is gone. The latest card opens the result:
/// what to do with it, the lines in Sous's form, and the recipe old and new.
///
/// A template starts the talk at once, since choosing it was the asking; a
/// request the cook types is the first message. Nothing is written before
/// they confirm on the result page. See ``RecipeEditChat``.
struct RecipeAIChatSheet: View {
    let recipe: Recipe
    let request: RecipeAIEditSheet.Request
    /// Hands over to copy and paste, for when the provider does not answer.
    let onFallback: () -> Void

    @Environment(RecipeLibrary.self) private var library
    @Environment(IngredientCatalogLibrary.self) private var catalogLibrary
    @Environment(NutritionLibrary.self) private var nutritionLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var connections = AIConnections.shared
    /// Set once the household's key was taken in place of the cook's own.
    @State private var usingHousehold: AIConnections.Resolved?
    @State private var chat: RecipeEditChat?
    @State private var draft: RecipeReplacementDraft
    @State private var input = ""
    @State private var categories: [String] = []
    @State private var isReviewing = false
    @State private var didAutoStart = false

    init(recipe: Recipe, request: RecipeAIEditSheet.Request, onFallback: @escaping () -> Void) {
        self.recipe = recipe
        self.request = request
        self.onFallback = onFallback
        _draft = State(initialValue: RecipeReplacementDraft(recipe: recipe, requestTitle: request.title))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let active = connections.active {
                    conversation(usingHousehold ?? active)
                } else {
                    notSetUp
                }
            }
            .navigationTitle(request.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $isReviewing) { reviewPage }
        }
        // The talk is work the cook would lose by a swipe.
        .interactiveDismissDisabled(chat != nil)
        .sousSheetSizing(.page)
        .onChange(of: chat?.proposal) { _, proposal in draft.replacement = proposal }
        .onChange(of: chat?.isAnswering) { _, answering in
            // The answer is whole: bring its lines into form, without a tap.
            if answering == false, draft.replacement != nil, let resolved = usingHousehold ?? connections.active {
                draft.tidy(
                    with: resolved.connection, catalog: catalogLibrary.catalog,
                    nutritionCatalog: nutritionLibrary.nutritionCatalog)
            }
        }
        .onDisappear {
            chat?.cancel()
            draft.cancel()
        }
        .task {
            categories = await library.categoryCounts()
                .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
                .prefix(80)
                .map(\.name)
            await HouseholdAIConnectionLibrary.shared.reloadNow()
            if let text = request.text, !didAutoStart, let active = connections.active {
                didAutoStart = true
                begin(task: text, with: active.connection)
            }
        }
    }

    // MARK: - The talk

    private func conversation(_ resolved: AIConnections.Resolved) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat == nil { startHint(resolved) }
                    if let chat {
                        ForEach(chat.turns) { turn in row(turn) }
                        if let partial = chat.partial, !partial.isEmpty {
                            modelText(RecipeEditChat.visible(partial).text)
                        }
                        if chat.isAnswering { ProgressView().padding(.leading, 4) }
                        if let failure = chat.failure { failureRow(failure, chat: chat) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat?.turns.count) { scrollDown(proxy) }
            .onChange(of: chat?.partial) { scrollDown(proxy) }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer(resolved.connection) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
    }

    private func startHint(_ resolved: AIConnections.Resolved) -> some View {
        let connection = resolved.connection
        return VStack(alignment: .leading, spacing: 6) {
            Text("Was soll sich am Rezept ändern?").font(.headline)
            Text("Schreibe es unten. Sous schickt das Rezept und deine Bitte an \(connection.provider.name) (\(connection.provider.model)). \(resolved.payer)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ turn: RecipeEditChat.Turn) -> some View {
        switch turn.kind {
        case .cook:
            Text(turn.text)
                .padding(10)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
        case .model:
            let shown = RecipeEditChat.visible(turn.text)
            VStack(alignment: .leading, spacing: 10) {
                if !shown.text.isEmpty { modelText(shown.text) }
                if shown.showsRecipe, case .success(let proposal) = RecipeReplacementPrompt.read(turn.text) {
                    RecipeProposalCard(
                        original: recipe, proposal: proposal,
                        isLatest: turn.id == chat?.turns.last(where: { $0.kind == .model })?.id,
                        onOpen: { isReviewing = true })
                }
            }
        case .note:
            Text(turn.text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modelText(_ text: String) -> some View {
        Text(AttributedString(inlineMarkdown: text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 20)
    }

    private func failureRow(_ message: String, chat: RecipeEditChat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
            // The cook's own key was refused or is used up: the household's is
            // offered, not taken, because then someone else pays.
            if (chat.failureError as? LLMError)?.isTheKeysFault == true,
                usingHousehold == nil, let other = connections.alternative
            {
                Button("Schlüssel des Haushalts verwenden (\(other.connection.provider.name))", systemImage: "person.2") {
                    usingHousehold = other
                    chat.retry(using: other.connection.client())
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Mit Kopieren und Einfügen weitermachen", systemImage: "doc.on.doc") { onFallback() }
                .buttonStyle(.bordered)
        }
    }

    private func composer(_ connection: AIConnection) -> some View {
        VStack(spacing: 8) {
            if draft.replacement != nil {
                Button { isReviewing = true } label: {
                    Label("Ergebnis ansehen und übernehmen", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(chat?.isAnswering == true)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat == nil ? "Was soll sich ändern?" : "Nachfrage", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                Button("Senden", systemImage: "arrow.up.circle.fill") { send(with: connection) }
                    .labelStyle(.iconOnly)
                    .font(.largeTitle)
                    .disabled(chat?.isAnswering == true || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func send(with connection: AIConnection) {
        let text = input
        input = ""
        if let chat {
            chat.send(text)
        } else {
            begin(task: text, with: connection)
        }
    }

    private func begin(task: String, with connection: AIConnection) {
        let started = RecipeEditChat(client: connection.client())
        chat = started
        let parts = RecipeReplacementPrompt.parts(
            task: task, for: recipe, catalog: catalogLibrary.catalog,
            categories: categories, showsRecipe: false)
        started.start(
            cachedPrefix: parts.prefix, then: parts.rest,
            // The recipe goes along; the transcript shows only what the cook asked.
            shown: task.replacingOccurrences(of: RecipeReplacementPrompt.placeholder, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var notSetUp: some View {
        ContentUnavailableView {
            Label("Kein KI-Anbieter eingerichtet", systemImage: "key.slash")
        } description: {
            Text("Richte ihn unter „Einstellungen“ › „KI“ ein, oder frage mit Kopieren und Einfügen.")
        } actions: {
            Button("Mit Kopieren und Einfügen", systemImage: "doc.on.doc") { onFallback() }
        }
    }

    // MARK: - The result

    private var reviewPage: some View {
        Form {
            RecipeReplacementSections(draft: draft, connection: (usingHousehold ?? connections.active)?.connection)
        }
        .formStyle(.grouped)
        .navigationTitle("Ergebnis")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) {
                    Task { if await draft.apply(to: library) { dismiss() } }
                }
                .disabled(draft.replacement == nil || draft.isTidying)
            }
        }
    }
}

/// A recipe a model proposed, as the chat shows it: the title, what is new and
/// what is gone against the recipe it started from, and the whole thing a tap
/// away. The latest card opens the result.
struct RecipeProposalCard: View {
    let original: Recipe
    let proposal: RecipeReplacement
    let isLatest: Bool
    let onOpen: () -> Void

    @State private var showsRecipe = false

    private var changes: RecipeReplacement.Changes { proposal.changes(from: original) }

    var body: some View {
        let changes = changes
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(proposal.title).font(SousStyle.groupHeading)
                Spacer(minLength: 8)
                if let servings = proposal.servings {
                    Label("\(servings)", systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                }
            }
            if changes.isEmpty {
                Text("Keine Änderung gegenüber dem Rezept.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes.added, id: \.self) { line in
                        Label(line, systemImage: "plus.circle.fill").foregroundStyle(.tint)
                    }
                    ForEach(changes.removed, id: \.self) { line in
                        Label(line, systemImage: "minus.circle")
                            .strikethrough()
                            .foregroundStyle(.secondary)
                    }
                    if changes.changedSteps > 0 {
                        Label(
                            changes.changedSteps == 1 ? "1 Schritt angepasst" : "\(changes.changedSteps) Schritte angepasst",
                            systemImage: "list.number"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            DisclosureGroup("Ganzes Rezept", isExpanded: $showsRecipe) {
                let shown = Recipe(
                    title: proposal.title, servings: proposal.servings ?? original.servings,
                    ingredientsText: proposal.ingredientsText, instructionsText: proposal.instructionsText)
                VStack(alignment: .leading, spacing: 16) {
                    IngredientsPreview(recipe: shown)
                    StepsPreview(recipe: shown)
                }
                .padding(.top, 6)
            }
            .font(.callout)
            if isLatest {
                Button("Ergebnis ansehen", action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }
}
