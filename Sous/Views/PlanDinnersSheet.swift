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
            destinationPicker
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

    /// One picker for both phases, so the choice reads the same before and
    /// after generating.
    private var destinationPicker: some View {
        Picker("Wohin", selection: $mode) {
            Text("Auf Tage verteilen").tag(DinnerPlannerLibrary.Mode.days)
            Text("In die Sammlung").tag(DinnerPlannerLibrary.Mode.pool)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Proposal

    @ViewBuilder
    private func proposalSections(_ proposal: PlanProposal) -> some View {
        // The destination stays a choice after the fact: the dishes were
        // picked for the mix, and re-addressing them costs nothing.
        Section {
            destinationPicker
                .onChange(of: mode) {
                    planner.reassign(mode: mode)
                }
        }
        .listRowBackground(Color.clear)
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
                // The visible label sits beside the toggle, not in it —
                // without this, VoiceOver announces a nameless switch.
                .accessibilityLabel(placement.candidate.title)
            if let imageID = planner.recipe(for: placement)?.imageIDs.first {
                RecipeImageView(imageID: imageID, thumbnail: true)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                dayLine(placement)
                Text(placement.candidate.title)
                    .font(SousStyle.recipeName)
                HStack(spacing: 6) {
                    // The list's rule travels along: an incomplete figure
                    // is shown as the floor it is, never naked.
                    if let kcal = placement.candidate.perPortion?.kcal, kcal > 0 {
                        Text(placement.candidate.isProvisional
                            ? "≈ \(Int(kcal.rounded())) kcal"
                            : "\(Int(kcal.rounded())) kcal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    provenance(placement)
                }
            }
            Spacer(minLength: 0)
            if !placement.candidate.isPool {
                // A silently disabled icon reads as a broken button, so a
                // failed swap says in words what happened: the collection
                // has no other dinner-worthy dish left to offer this seat.
                if exhausted.contains(placement.id) {
                    Text("Keine Alternative")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Button {
                        if planner.swap(placement) {
                            deselected.remove(placement.id)
                        } else {
                            exhausted.insert(placement.id)
                        }
                    } label: {
                        Label("Austauschen", systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Gegen einen anderen Vorschlag tauschen")
                }
            }
        }
        .opacity(isOn.wrappedValue ? 1 : 0.4)
    }

    /// The day above the dish — and the way to choose it: a menu over the
    /// free evenings, unoccupied ones included, because an evening is not
    /// obliged to hold a recipe. Picking an empty evening moves the dish
    /// there and leaves its old one empty; picking an occupied one swaps
    /// the two; "In die Sammlung" takes it off the days without unpicking
    /// it. In pool mode the whole line stays quiet — there is nothing to
    /// address.
    @ViewBuilder
    private func dayLine(_ placement: PlanProposal.Placement) -> some View {
        if mode == .days {
            let occupants: [Date: String] = {
                guard case .ready(let proposal) = planner.phase else { return [:] }
                return Dictionary(
                    uniqueKeysWithValues: proposal.placements.compactMap { seated in
                        seated.day.map { ($0, seated.candidate.title) }
                    }
                )
            }()
            Menu {
                ForEach(planner.availableDinnerDays(), id: \.self) { target in
                    Button {
                        planner.move(placement, to: target)
                    } label: {
                        if target == placement.day {
                            Label(dayText(target), systemImage: "checkmark")
                        } else if let dish = occupants[target] {
                            // The swap partner, named — choosing a taken
                            // evening should not be a surprise.
                            Text("\(dayText(target)) — \(dish)")
                        } else {
                            Text(dayText(target))
                        }
                    }
                }
                Divider()
                Button {
                    planner.move(placement, to: nil)
                } label: {
                    if placement.day == nil {
                        Label("In die Sammlung", systemImage: "checkmark")
                    } else {
                        Text("In die Sammlung")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if let day = placement.day {
                        Text(day, format: .dateTime.weekday(.wide))
                        Text(day, format: .dateTime.day().month())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("In die Sammlung")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    private func dayText(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.wide).day().month().locale(.sous))
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
        VStack(alignment: .leading, spacing: 4) {
            if let summary = planner.summary(selecting: selected) {
                Text(summaryText(summary))
            }
            // Fewer rows than asked for is a fact about the collection, not
            // a fault of the run — and the difference has to be sayable, or
            // "immer vier" reads as a broken planner.
            if proposal.placements.count < count {
                Text(planner.leftOutWithoutFigures > 0
                    ? "Mehr kommt nicht in Frage — \(planner.leftOutWithoutFigures) Rezepte bleiben ohne berechenbare Nährwerte außen vor."
                    : "Mehr gibt die Sammlung gerade nicht her.")
            }
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
