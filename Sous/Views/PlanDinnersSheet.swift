import SousKit
import SwiftUI

/// Lets the planner propose dinners: how many, and whether they land on
/// the next free days or in the undated Sammlung. Everything on this sheet
/// is a suggestion until "Übernehmen" — rows can be unticked, and every
/// suggested dish can be traded for the next-best alternative.
struct PlanDinnersSheet: View {
    @Environment(DinnerPlannerLibrary.self) private var planner
    @Environment(\.dismiss) private var dismiss

    /// Where the run was opened from, which is where its dinners probably
    /// belong — the calendar proposes onto days, the Sammlung into itself.
    let defaultMode: DinnerPlannerLibrary.Mode

    @State private var mode: DinnerPlannerLibrary.Mode
    @State private var count = 7
    /// Unticked rows. The complement of a selection, so a fresh proposal
    /// starts all-on without anything having to be synchronized.
    @State private var deselected: Set<UUID> = []
    /// Rows whose alternatives ran dry, so the swap button can say so.
    @State private var exhausted: Set<UUID> = []

    init(defaultMode: DinnerPlannerLibrary.Mode) {
        self.defaultMode = defaultMode
        _mode = State(initialValue: defaultMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                content
            }
            .formStyle(.grouped)
            .navigationTitle("Essen planen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                if case .ready(let proposal) = planner.phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Übernehmen") {
                            let accepted = proposal.placements.filter { !deselected.contains($0.id) }
                            Task {
                                await planner.apply(accepted)
                                dismiss()
                            }
                        }
                        .disabled(proposal.placements.allSatisfy { deselected.contains($0.id) })
                    }
                }
            }
        }
        .sousSheetSizing(.form)
        .onDisappear { planner.reset() }
    }

    @ViewBuilder
    private var content: some View {
        switch planner.phase {
        case .idle:
            setup
        case .loading(let progress):
            Section {
                ProgressView(value: progress) {
                    Text("Nährwerte werden berechnet…")
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
        case .ready(let proposal):
            proposalSections(proposal)
        case .empty(let reason):
            emptyState(reason)
        }
    }

    // MARK: - Setup

    @ViewBuilder
    private var setup: some View {
        Section {
            Stepper(value: $count, in: 1...14) {
                Label("\(count) Gerichte", systemImage: "fork.knife")
            }
            Picker("Wohin", selection: $mode) {
                Text("Auf Tage verteilen").tag(DinnerPlannerLibrary.Mode.days)
                Text("In die Sammlung").tag(DinnerPlannerLibrary.Mode.pool)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } footer: {
            Text(mode == .days
                ? "Vorschläge für die nächsten Abende ohne geplantes Abendessen — zusammengestellt als ausgewogene Mischung, Vorgemerktes zuerst."
                : "Vorschläge für die Sammlung, als Ergänzung zu dem, was schon darin liegt — ohne festen Tag.")
        }
        Section {
            Button {
                propose(excluding: [])
            } label: {
                Label("Vorschlagen", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Proposal

    @ViewBuilder
    private func proposalSections(_ proposal: PlanProposal) -> some View {
        Section {
            ForEach(proposal.placements) { placement in
                placementRow(placement)
            }
        } footer: {
            summaryFooter(proposal)
        }
        Section {
            Button("Neu vorschlagen", systemImage: "arrow.clockwise") {
                propose(excluding: deselected)
            }
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func placementRow(_ placement: PlanProposal.Placement) -> some View {
        let isOn = Binding<Bool>(
            get: { !deselected.contains(placement.id) },
            set: { included in
                if included {
                    deselected.remove(placement.id)
                } else {
                    deselected.insert(placement.id)
                }
            }
        )
        HStack(spacing: 12) {
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkboxCircle)
            if let imageID = planner.recipe(for: placement)?.imageIDs.first {
                RecipeImageView(imageID: imageID, thumbnail: true)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                if let day = placement.day {
                    HStack(spacing: 4) {
                        Text(day, format: .dateTime.weekday(.wide))
                        Text(day, format: .dateTime.day().month())
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Text(placement.candidate.title)
                    .font(SousStyle.recipeName)
                provenance(placement)
            }
            Spacer(minLength: 0)
            if !placement.candidate.isPool {
                Button {
                    if planner.swap(placement) {
                        deselected.remove(placement.id)
                    } else {
                        exhausted.insert(placement.id)
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .disabled(exhausted.contains(placement.id))
                .help("Gegen einen anderen Vorschlag tauschen")
            }
        }
        .opacity(isOn.wrappedValue ? 1 : 0.4)
    }

    @ViewBuilder
    private func provenance(_ placement: PlanProposal.Placement) -> some View {
        if placement.candidate.isPool {
            Label("Aus der Sammlung", systemImage: "tray")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if placement.candidate.isWantToCook {
            Label("Will ich kochen", systemImage: "star.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func summaryFooter(_ proposal: PlanProposal) -> some View {
        let selected = Set(proposal.placements.map(\.id)).subtracting(deselected)
        if let summary = planner.summary(selecting: selected) {
            Text(summaryText(summary))
        }
    }

    /// "Ballaststoffe knapp · Natrium hoch" — only what is worth a word;
    /// a mix with nothing to report says so in one.
    private func summaryText(_ summary: MixSummary) -> String {
        let findings = summary.findings
        guard !findings.isEmpty else { return "Ausgewogene Mischung." }
        return findings
            .map { "\($0.label) \($0.status == .short ? "knapp" : "hoch")" }
            .joined(separator: " · ")
    }

    // MARK: - Empty states

    @ViewBuilder
    private func emptyState(_ reason: DinnerPlannerLibrary.EmptyReason) -> some View {
        Section {
            switch reason {
            case .noEmptySlots:
                ContentUnavailableView {
                    Label("Alles geplant", systemImage: "calendar.badge.checkmark")
                } description: {
                    Text("Die nächsten Abende haben schon ein Abendessen.")
                }
            case .noCandidates:
                ContentUnavailableView {
                    Label("Nichts vorzuschlagen", systemImage: "fork.knife")
                } description: {
                    Text("Kein Rezept kommt in Frage — Vorschläge brauchen Rezepte mit berechenbaren Nährwerten, die als Abendessen passen.")
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private func propose(excluding: Set<UUID>) {
        deselected = []
        exhausted = []
        Task { await planner.propose(mode: mode, count: count, excluding: excluding) }
    }
}

/// A round tick, since the plain switch reads as a setting rather than a
/// choice of rows.
private struct CheckboxCircleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == CheckboxCircleToggleStyle {
    static var checkboxCircle: CheckboxCircleToggleStyle { CheckboxCircleToggleStyle() }
}
