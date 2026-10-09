import SousKit
import SwiftUI

/// Where the cook sets up a chat provider Sous may ask itself: the provider,
/// the key, and the model. The key is checked by asking the provider for its
/// model list, which costs nothing, and the list is what the model is
/// picked from.
struct AIConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    /// Where it is kept: the cook's own keychain or the household.
    let ai: any AIConnectionEditing

    /// The presets, then "Eigener Anbieter" as the last choice.
    private static let customTag = "custom"

    @State private var choice = LLMProvider.presets[0].name
    @State private var customName = ""
    @State private var customKind = LLMProviderKind.openAICompatible
    @State private var customURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var models: [LLMModel] = []
    @State private var isLoading = false
    @State private var problem: String?
    @State private var didLoad = false

    private var isCustom: Bool { choice == Self.customTag }

    /// The provider as the cook picks it. Only their pick clears the model:
    /// loading a saved connection sets the choice too, and must keep its model.
    private var chosen: Binding<String> {
        Binding(
            get: { choice },
            set: { new in
                guard new != choice else { return }
                choice = new
                // A key and a model belong to one provider.
                model = ""
                models = []
                problem = nil
            }
        )
    }

    /// The provider as the form describes it right now.
    private var provider: LLMProvider? {
        if isCustom {
            guard let url = URL(string: customURL.trimmingCharacters(in: .whitespaces)), url.host() != nil else { return nil }
            let name = customName.trimmingCharacters(in: .whitespaces)
            // Unnamed, it goes by its server: "Mit api.example.com bearbeiten".
            return LLMProvider(name: name.isEmpty ? (url.host() ?? "Eigener Anbieter") : name, kind: customKind, baseURL: url, model: model)
        }
        guard var preset = LLMProvider.presets.first(where: { $0.name == choice }) else { return nil }
        preset.model = model
        return preset
    }

    private var draft: AIConnection? {
        provider.map {
            AIConnection(
                provider: LLMModelAdvice.tuned($0),
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private var suggestions: [LLMModel] {
        provider.map { LLMModelAdvice.suggestions(in: models, for: $0) } ?? []
    }

    var body: some View {
        Form {
            Section {
                Picker("Anbieter", selection: chosen) {
                    ForEach(LLMProvider.presets, id: \.name) { Text($0.name).tag($0.name) }
                    Text("Eigener Anbieter").tag(Self.customTag)
                }
                if isCustom {
                    TextField("Name", text: $customName)
                    Picker("Format", selection: $customKind) {
                        Text("OpenAI-kompatibel").tag(LLMProviderKind.openAICompatible)
                        Text("Anthropic").tag(LLMProviderKind.anthropic)
                    }
                    TextField("Adresse, z. B. https://api.example.com/v1", text: $customURL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
            } footer: {
                if isCustom {
                    Text("Server, die das OpenAI-Format sprechen — etwa Ollama oder LM Studio —, brauchen keinen Schlüssel.")
                }
            }

            Section {
                Label {
                    Text(AIAPINote.text)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                SecureField("API-Schlüssel", text: $apiKey)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    // An API key is no password for the system to offer saving: it
                    // lives in the keychain by Sous's own hand.
                    .textContentType(.oneTimeCode)
                    #endif
                if let page = provider?.keyPage {
                    Link(destination: page) {
                        Label("Schlüssel bei \(provider?.name ?? "") erstellen", systemImage: "arrow.up.forward.app")
                    }
                }
                Button(models.isEmpty ? "Schlüssel prüfen und Modelle laden" : "Modelle neu laden", systemImage: "key") {
                    loadModels()
                }
                .disabled(isLoading || provider == nil || (apiKey.isEmpty && provider?.isLocal != true))
                if isLoading { ProgressView() }
                if let problem {
                    Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            } header: {
                Text("Schlüssel")
            } footer: {
                if ai.isHousehold {
                    Text("Der Schlüssel liegt verschlüsselt im Haushalt. Alle im Haushalt können damit fragen, auf Kosten dessen, der ihn eingerichtet hat. Wer im Haushalt schreiben darf, kann ihn auch ändern oder entfernen.")
                } else {
                    Text("Der Schlüssel liegt im iCloud-Schlüsselbund und folgt dir auf deine anderen Geräte. Er wird nirgends sonst gespeichert.")
                }
            }

            modelSection

            if let error = ai.storeError {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }

            if ai.connection != nil {
                Section {
                    Button("Verbindung entfernen", role: .destructive) {
                        ai.remove()
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(ai.isHousehold ? "KI-Anbieter des Haushalts" : "KI-Anbieter")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) {
                    if let draft { ai.save(draft) }
                    dismiss()
                }
                .disabled(draft?.isUsable != true)
            }
        }
        .task {
            guard !didLoad else { return }
            ai.reload()
            if let connection = ai.connection { adopt(connection) }
            didLoad = true
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section {
            if models.isEmpty {
                TextField("Modell", text: $model)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } else {
                Picker("Modell", selection: $model) {
                    if model.isEmpty { Text("Nicht gewählt").tag("") }
                    if !suggestions.isEmpty {
                        Section("Empfohlen") {
                            ForEach(suggestions) { Text($0.name).tag($0.id) }
                        }
                    }
                    Section("Alle") {
                        ForEach(LLMModelAdvice.chatModels(models)) { Text($0.name).tag($0.id) }
                    }
                }
            }
        } header: {
            Text("Modell")
        } footer: {
            Text("""
            Kleine, günstige Modelle reichen für Sous. Die Empfehlung hat Sous an \
            Beispielrezepten ausprobiert; größere Modelle sind teurer und meist langsamer.
            """)
        }
    }

    // MARK: -

    private func adopt(_ connection: AIConnection) {
        let provider = connection.provider
        if LLMProvider.presets.contains(where: { $0.name == provider.name }) {
            choice = provider.name
        } else {
            choice = Self.customTag
            customName = provider.name
            customKind = provider.kind
            customURL = provider.baseURL.absoluteString
        }
        apiKey = connection.apiKey
        model = provider.model
    }

    private func loadModels() {
        guard let draft else { return }
        isLoading = true
        problem = nil
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let loaded = try await draft.client().models()
                models = loaded
                // A model already chosen stays; otherwise the first suggestion is preselected.
                if model.isEmpty || !loaded.contains(where: { $0.id == model }) {
                    model = suggestions.first?.id ?? ""
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The entry in the settings. On the Mac the `Settings` scene has no
/// navigation stack, so the page opens in a sheet there.
struct AIConnectionSettingsRow: View {
    /// The cook's own, or the household's.
    let ai: any AIConnectionEditing

    #if os(macOS)
    @State private var isShowingPage = false
    #endif

    var body: some View {
        Section {
            #if os(macOS)
            Button { isShowingPage = true } label: { label }
                .sheet(isPresented: $isShowingPage) {
                    NavigationStack {
                        AIConnectionView(ai: ai)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(role: .close) { isShowingPage = false }
                                }
                            }
                    }
                    .sousSheetSizing(.page)
                }
            #else
            NavigationLink { AIConnectionView(ai: ai) } label: { label }
            #endif
        } footer: {
            if ai.isHousehold {
                Text("Alle im Haushalt fragen darüber, wenn sie keinen eigenen Schlüssel haben. Dabei gehen der Rezepttext und die Notizen an den Anbieter.")
            } else {
                Text("""
                Mit einem eigenen Schlüssel fragt Sous das Modell selbst, ohne Kopieren und Einfügen. \
                Dabei gehen der Rezepttext und die Notizen an den Anbieter.
                """)
            }
        }
        .onAppear { ai.reload() }
    }

    private var label: some View {
        LabeledContent {
            Text(ai.connection.flatMap { $0.isUsable ? $0.provider.name : nil } ?? "Nicht eingerichtet")
        } label: {
            Label(ai.isHousehold ? "KI-Anbieter des Haushalts" : "KI-Anbieter", systemImage: "key")
        }
    }
}


/// What a cook should know before making a key.
enum AIAPINote {
    static let text = """
    Ein Abo (etwa ChatGPT Plus, Claude Pro, SuperGrok oder Gemini Advanced) gilt nicht für die API. \
    Die API hat einen eigenen Schlüssel und wird getrennt nach Verbrauch abgerechnet, meist mit \
    Guthaben, das du dort auflädst. Ein Rezept kostet je nach Modell Bruchteile eines Cents bis \
    wenige Cent.
    """
}
