import SousKit
import SwiftUI

/// "Anpassungen teilen" (INGREDIENTS-DATA §3 D): the household's
/// own adjustments of the catalog, grouped, all ticked, each shown exactly as
/// it is sent. ✓ sends the ticked ones as one `CatalogSubmission` to the
/// public database, where the nightly job in the private inbox repository
/// picks them up; they are then marked shared and not offered again until
/// they change.
///
/// Without an iCloud account it offers the public issue form on GitHub and
/// copying as text instead.
struct CatalogShareSheet: View {
    enum Source: Hashable, Identifiable {
        /// Every pending answer — the nudge card and Settings.
        case pending
        /// One name nobody answered — "An den Katalog melden" on its line.
        case unknown(String)

        var id: String {
            switch self {
            case .pending: "pending"
            case .unknown(let name): "unknown:\(name)"
            }
        }
    }

    let source: Source

    @Environment(IngredientCatalogLibrary.self) private var catalog
    /// Optional: the share extension edits one recipe and holds no library.
    @Environment(RecipeLibrary.self) private var library: RecipeLibrary?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var offers: [CatalogSharing.Offer]?
    @State private var ticked: Set<String> = []
    @State private var account: CatalogSubmissionAccount?
    @State private var isSending = false
    @State private var failure: String?

    private let sender: any CatalogSubmissionSender = CloudKitSubmissionSender()
    private var log: CatalogSubmissionLog { CatalogSubmissionLog(defaults: .sous) }

    var body: some View {
        NavigationStack {
            Form {
                if let offers {
                    if offers.isEmpty {
                        Section {
                            Text("Gerade gibt es nichts zu teilen. Was du lokal angibst, wirkt sofort und taucht hier auf, bis du es teilst.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        content(offers)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Anpassungen teilen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                if account != CatalogSubmissionAccount.none {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Teilen") { Task { await send() } }
                            .disabled(chosen.isEmpty || isSending || account != .available || !log.canSend())
                    }
                }
            }
        }
        .task { await load() }
        .sousSheetSizing(.form)
    }

    @ViewBuilder
    private func content(_ offers: [CatalogSharing.Offer]) -> some View {
        Section {
            Text("Diese Angaben hat dein Haushalt selbst gemacht. Geteilt prüft sie der Katalog und übernimmt sie für alle. Gesendet wird genau das, was hier steht – ohne Haushalt und ohne Rezepttitel.")
                .font(.callout)
        }
        ForEach(CatalogSharing.Group.allCases, id: \.self) { group in
            let members = offers.filter { CatalogSharing.Group($0.item.kind) == group }
            if !members.isEmpty {
                Section {
                    ForEach(members) { offer in
                        row(offer)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    Text(group.footer)
                }
            }
        }
        if account == CatalogSubmissionAccount.none {
            withoutAccount
        } else if account == .unavailable {
            Section {
                Text("iCloud ist auf diesem Gerät gerade nicht bereit. Prüf in den Einstellungen deinen Apple Account – oft will iCloud das Passwort oder neue Bedingungen bestätigt haben.")
                    .foregroundStyle(.secondary)
                Button("Noch einmal prüfen", systemImage: "arrow.clockwise") {
                    Task { account = await sender.account() }
                }
            }
        } else if !log.canSend() {
            Section {
                Text("Heute hast du schon dreimal geteilt. Morgen geht es wieder.")
                    .foregroundStyle(.secondary)
            }
        }
        if chosen.count > CatalogSubmission.maximumItems {
            Section {
                Text("Höchstens \(CatalogSubmission.maximumItems) Angaben auf einmal; der Rest bleibt für das nächste Mal.")
                    .foregroundStyle(.secondary)
            }
        }
        if let failure {
            Section {
                Text(failure)
                    .foregroundStyle(.red)
            }
        }
    }

    private func row(_ offer: CatalogSharing.Offer) -> some View {
        Toggle(isOn: Binding(
            get: { ticked.contains(offer.id) },
            set: { if $0 { ticked.insert(offer.id) } else { ticked.remove(offer.id) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.item.name)
                Text(offer.item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let context = offer.item.context {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isSending)
    }

    /// No iCloud account: the public issue form, or the text to send some
    /// other way. Either counts as shared — the sheet cannot see whether the
    /// form was sent, and asking again every 30 days would not help.
    private var withoutAccount: some View {
        Section {
            if let url = submission.issueFormURL {
                Button("Auf GitHub melden", systemImage: "arrow.up.forward.app") {
                    openURL(url)
                    Task { await markShared() }
                }
                .disabled(chosen.isEmpty)
            }
            Button("Als Text kopieren", systemImage: "doc.on.doc") {
                SousPasteboard.copy(submission.text)
                Task { await markShared() }
            }
            .disabled(chosen.isEmpty)
        } header: {
            Text("Ohne iCloud")
        } footer: {
            Text("Sous teilt direkt nur mit einem iCloud-Konto. Das Formular auf GitHub braucht ein GitHub-Konto und ist öffentlich lesbar.")
        }
    }

    // MARK: - Doing it

    private var chosen: [CatalogSharing.Offer] {
        (offers ?? []).filter { ticked.contains($0.id) }
    }

    private var submission: CatalogSubmission {
        CatalogSubmission(items: chosen.map(\.item), app: Self.appVersion, dataVersion: catalog.dataSet.dataVersion)
    }

    private func load() async {
        let texts = await library?.allRecipes().map(\.ingredientsText) ?? []
        let household = catalog.catalog
        let usage = await Task.detached(priority: .userInitiated) {
            CatalogUsage(ingredientTexts: texts, catalog: household)
        }.value
        let loaded: [CatalogSharing.Offer] = switch source {
        case .pending: catalog.shareOffers(usage: usage)
        case .unknown(let name): [CatalogSharing.unknown(name, usage: usage)]
        }
        offers = loaded
        ticked = Set(loaded.map(\.id))
        account = await sender.account()
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        failure = nil
        let submission = submission
        do {
            try await sender.send(submission)
        } catch {
            failure = error.message
            if error == .noAccount { account = CatalogSubmissionAccount.none }
            return
        }
        log.record()
        await markShared()
        dismiss()
    }

    /// Only what went out: the first fifty of the ticked.
    private func markShared() async {
        let sent = Array(chosen.prefix(CatalogSubmission.maximumItems))
        CatalogNudge(defaults: .sous).restart()
        await catalog.markShared(sent)
        let sentIDs = Set(sent.map(\.id))
        offers?.removeAll { sentIDs.contains($0.id) }
        ticked.subtract(sentIDs)
    }

    /// "1.0 (12)".
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// The quiet card that suggests sharing (§3 D): at least five pending
/// answers, and at least 30 days since "Später" or the last share. Never
/// modal, never in cook mode, never a notification — a section of the
/// catalog view and of Settings, which hides itself otherwise.
struct CatalogNudgeCard: View {
    /// Optional: the Mac's settings scene may come without the library.
    @Environment(IngredientCatalogLibrary.self) private var catalog: IngredientCatalogLibrary?
    @AppStorage(CatalogNudge.neverAskKey, store: .sous) private var neverAsk = false
    /// Read so the card redraws once "Später" moved the clock.
    @AppStorage(CatalogNudge.lastKey, store: .sous) private var last: Double = 0

    @State private var isSharing = false

    var body: some View {
        if let catalog, CatalogNudge(defaults: .sous).shows(pending: catalog.pendingShareCount) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Du hast \(catalog.pendingShareCount) eigene Anpassungen am Katalog.")
                                .font(.subheadline.weight(.semibold))
                            Text("Teilen, damit alle sie bekommen?")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.tint)
                    }
                    HStack {
                        Button("Ansehen & teilen") { isSharing = true }
                            .buttonStyle(.borderedProminent)
                        Button("Später") { CatalogNudge(defaults: .sous).restart() }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                        Button("Nicht mehr fragen") { neverAsk = true }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            .sheet(isPresented: $isSharing) {
                CatalogShareSheet(source: .pending)
            }
        }
    }
}

/// Sharing in Settings: always reachable, whatever the card does, and the
/// way back from "Nicht mehr fragen".
struct CatalogSharingSettingsSection: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog: IngredientCatalogLibrary?
    @AppStorage(CatalogNudge.neverAskKey, store: .sous) private var neverAsk = false

    @State private var isSharing = false

    var body: some View {
        if let catalog {
            Section {
                Button("Anpassungen teilen …") { isSharing = true }
                LabeledContent("Noch nicht geteilt") {
                    Text(verbatim: String(catalog.pendingShareCount))
                }
                Toggle("Ans Teilen erinnern", isOn: Binding(get: { !neverAsk }, set: { neverAsk = !$0 }))
            } header: {
                Text("Anpassungen am Katalog")
            } footer: {
                Text("Eigene Angaben wirken sofort in deinem Haushalt. Geteilt prüft sie der Katalog und übernimmt sie für alle. Gesendet wird nur, was du beim Teilen siehst.")
            }
            .sheet(isPresented: $isSharing) {
                CatalogShareSheet(source: .pending)
            }
        }
    }
}
