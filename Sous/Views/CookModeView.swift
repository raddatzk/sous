import SousKit
import SwiftUI

/// Full-screen step-by-step cooking, with the ingredients a tap away and the
/// display kept awake.
struct CookModeView: View {
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe
    /// The serving count the reader had chosen, so the amounts match what
    /// they were just looking at.
    let servings: Int

    @State private var stepIndex = 0
    @State private var showingIngredients = false
    @State private var checkedIngredients: Set<UUID> = []
    @State private var timer: StepTimer?

    private let formatter = QuantityFormatter()

    private var steps: [RecipeStep] { recipe.steps }
    private var currentStep: RecipeStep? {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    /// The number shown for the current step, restarting within its group.
    private var currentNumber: Int {
        guard let currentStep else { return 0 }
        let group = currentStep.group
        return steps[...stepIndex].filter { $0.group == group }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
            Divider()
            controls
        }
        .background(.background)
        .sheet(isPresented: $showingIngredients) { ingredientList }
        .onAppear { keepDisplayAwake(true) }
        .onDisappear { keepDisplayAwake(false) }
        #if os(iOS)
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    if value.translation.width < 0 { advance(by: 1) }
                    if value.translation.width > 0 { advance(by: -1) }
                }
        )
        #endif
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Button("Fertig") { dismiss() }
            Spacer()
            VStack(spacing: 2) {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("Schritt \(stepIndex + 1) von \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Zutaten", systemImage: "list.bullet") { showingIngredients = true }
                .labelStyle(.iconOnly)
        }
        .padding()
    }

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let group = currentStep?.group {
                    Text(group)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("\(currentNumber)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.tint)
                    Text(markdown(currentStep?.text ?? ""))
                        .font(.title3)
                }
                if let seconds = currentStep?.durationSeconds, seconds > 0 {
                    timerControl(seconds: seconds)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func timerControl(seconds: Int) -> some View {
        HStack(spacing: 12) {
            if let timer, timer.stepID == currentStep?.id {
                Text(timer.formattedRemaining)
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.isFinished ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Button(timer.isFinished ? "Zurücksetzen" : "Stopp") {
                    self.timer = nil
                }
            } else {
                Button("Timer \(seconds / 60 > 0 ? "\(seconds / 60) Min." : "\(seconds) Sek.")", systemImage: "timer") {
                    if let id = currentStep?.id {
                        timer = StepTimer(stepID: id, seconds: seconds)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            Button("Zurück", systemImage: "chevron.left") { advance(by: -1) }
                .disabled(stepIndex == 0)
            Spacer()
            Button("Weiter", systemImage: "chevron.right") { advance(by: 1) }
                .disabled(stepIndex >= steps.count - 1)
        }
        .buttonStyle(.bordered)
        .padding()
    }

    @ViewBuilder
    private var ingredientList: some View {
        NavigationStack {
            List {
                ForEach(recipe.ingredientGroups(scaledToServings: servings), id: \.group) { group in
                    Section(group.group ?? "Zutaten") {
                        ForEach(group.ingredients) { ingredient in
                            Button {
                                toggle(ingredient.id)
                            } label: {
                                HStack {
                                    Image(systemName: checkedIngredients.contains(ingredient.id)
                                        ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.tint)
                                    Text(markdown(formatter.string(for: ingredient)))
                                        .strikethrough(checkedIngredients.contains(ingredient.id))
                                        .foregroundStyle(checkedIngredients.contains(ingredient.id)
                                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Zutaten")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { showingIngredients = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }

    private func advance(by offset: Int) {
        let target = stepIndex + offset
        guard steps.indices.contains(target) else { return }
        stepIndex = target
    }

    private func toggle(_ id: UUID) {
        if checkedIngredients.contains(id) {
            checkedIngredients.remove(id)
        } else {
            checkedIngredients.insert(id)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// Hands covered in dough cannot tap a screen that has gone dark.
    private func keepDisplayAwake(_ enabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = enabled
        #endif
    }
}

/// A countdown for one step.
@MainActor
@Observable
private final class StepTimer {
    let stepID: UUID
    private(set) var remaining: Int

    init(stepID: UUID, seconds: Int) {
        self.stepID = stepID
        remaining = seconds
        // Holding the timer weakly is the whole cancellation mechanism:
        // dropping the object ends the loop on its next tick.
        Task { [weak self] in
            while let self, self.remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                self.remaining -= 1
            }
        }
    }

    var isFinished: Bool { remaining <= 0 }

    var formattedRemaining: String {
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension View {
    /// `fullScreenCover` does not exist on macOS; a sheet is the closest fit.
    @ViewBuilder
    func fullScreenCoverIfAvailable<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}
