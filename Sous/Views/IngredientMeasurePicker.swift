import SousKit
import SwiftUI

/// What one spoon, piece or cup of an ingredient weighs — the other half of
/// the concept's gram bridge, and the other thing a figure may be wrong about.
///
/// Built the same way as ``IngredientBasisPicker`` and for the same reason:
/// the question becomes visible inside the coverage drill-down, and answering
/// it there unfolds in place rather than opening anything. The basis picker
/// answers "which food is this"; this one answers "how much of it is that".
///
/// Every number it offers is an assumption — the measure table says so per
/// entry — so the field starts filled with what the app currently believes
/// and the cook overwrites it. Taking the correction back leaves the shipped
/// value standing, it does not leave the line without a weight.
struct IngredientMeasurePicker: View {
    @Environment(NutritionLibrary.self) private var nutrition

    /// The ingredient as it is written — resolved through the catalog, so a
    /// correction holds for every spelling and every recipe.
    let name: String
    /// The unit the line used. A correction is per unit: saying what an
    /// Esslöffel of honey weighs says nothing about a litre of it.
    let unit: IngredientUnit
    var onDecision: () async -> Void = {}

    @State private var text = ""
    @State private var hasLoaded = false

    private var current: Double? { nutrition.unitWeight(unit, forName: name) }
    private var isOwn: Bool { nutrition.hasOwnUnitWeight(unit, forName: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("1 \(unit.symbol) \(name) wiegt")
                TextField("g", text: $text)
                    .frame(maxWidth: 70)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Text("g")
                Spacer(minLength: 0)
            }
            Text(isOwn
                 ? "Deine Angabe — sie gilt für jedes Rezept mit dieser Zutat."
                 : "Angenommen. Was du hier einträgst, gilt für jedes Rezept mit dieser Zutat.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Sichern", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(DecimalText.number(text) == nil)
                if isOwn {
                    Button("Zurücknehmen", role: .destructive) {
                        decide { await nutrition.setUnitWeight(nil, unit: unit, forName: name) }
                    }
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .font(.footnote)
        .padding(.vertical, 4)
        // Filled after the load, not on appear: what the cook already
        // corrected is not known until the store has answered.
        .task {
            guard !hasLoaded else { return }
            await nutrition.ensureLoaded()
            text = current.map(DecimalText.text) ?? ""
            hasLoaded = true
        }
    }

    private func save() {
        guard let grams = DecimalText.number(text), grams > 0 else { return }
        decide { await nutrition.setUnitWeight(grams, unit: unit, forName: name) }
    }

    private func decide(_ work: @escaping () async -> Void) {
        Task {
            await work()
            await onDecision()
        }
    }
}
