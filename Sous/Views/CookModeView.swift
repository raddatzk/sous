import SousKit
import SwiftUI

/// Full-screen cooking: the steps scroll continuously with the current one in
/// focus, and the full ingredient list is one swipe to the left.
struct CookModeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RecipeLibrary.self) private var library

    let recipe: Recipe
    /// The serving count the reader had chosen, so every amount shown here —
    /// in the list and inside the step text — matches what they were reading.
    let servings: Int

    @State private var focusedStepID: RecipeStep.ID?
    @State private var checkedIngredients: Set<UUID> = []
    @State private var timer: StepTimer?

    /// Whether the last step has been in focus at any point. Kept as state
    /// rather than compared on the way out, because scrolling back up to
    /// check something does not undo having cooked the dish.
    @State private var didReachLastStep = false

    private let formatter = QuantityFormatter(locale: .sous)

    private var steps: [RecipeStep] { recipe.steps }

    private var focusedIndex: Int {
        steps.firstIndex { $0.id == focusedStepID } ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pages
        }
        .background(Color.sousCookBackground)
        // Cook mode is presented over the app, and a sheet does not pick up
        // a change to the window's scheme — so it names the same one again.
        .sousAppearance()
        .onAppear {
            focusedStepID = steps.first?.id
            didReachLastStep = steps.count <= 1
            keepDisplayAwake(true)
        }
        .onDisappear { keepDisplayAwake(false) }
        .onChange(of: focusedStepID) {
            if focusedStepID == steps.last?.id { didReachLastStep = true }
        }
    }

    @ViewBuilder
    private var pages: some View {
        #if os(iOS)
        TabView {
            stepsPage
            ingredientsPage
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        #else
        HStack(spacing: 0) {
            stepsPage
            Divider()
            ingredientsPage.frame(width: 320)
        }
        #endif
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Button("Fertig") { finish() }
            Spacer()
            VStack(spacing: 2) {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("Schritt \(focusedIndex + 1) von \(steps.count) · \(servings) Portionen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Balances the leading button so the title stays centred.
            Button("Fertig") {}.opacity(0).disabled(true)
        }
        .padding()
    }

    /// All steps in one scroll, the focused one at full strength and the rest
    /// dimmed — the cook keeps their place without tapping anything.
    @ViewBuilder
    private var stepsPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    stepCard(step, number: number(for: step, at: index))
                        .id(step.id)
                        .opacity(step.id == focusedStepID ? 1 : 0.4)
                        .animation(.easeInOut(duration: 0.2), value: focusedStepID)
                        .onTapGesture { focusedStepID = step.id }
                }
                Color.clear.frame(height: 200)
            }
            .scrollTargetLayout()
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .scrollPosition(id: $focusedStepID, anchor: .top)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func stepCard(_ step: RecipeStep, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let group = step.group, isFirstOfGroup(step) {
                Text(group)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("\(number)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.tint)
                    .frame(minWidth: 44, alignment: .trailing)
                Text(markdown(recipe.scaledStepText(step, toServings: servings)))
                    .font(.title3)
            }

            let used = recipe.ingredients(mentionedIn: step, scaledToServings: servings)
            if !used.isEmpty {
                // What this step needs, so the cook does not swipe away mid-task.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(used) { ingredient in
                        IngredientLineView(ingredient: ingredient, formatter: formatter)
                            .font(.callout)
                    }
                }
                .padding(.leading, 60)
            }

            if let seconds = step.durationSeconds, seconds > 0 {
                timerControl(step: step, seconds: seconds)
                    .padding(.leading, 60)
            }
        }
    }

    @ViewBuilder
    private func timerControl(step: RecipeStep, seconds: Int) -> some View {
        HStack(spacing: 12) {
            if let timer, timer.stepID == step.id {
                Text(timer.formattedRemaining)
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.isFinished ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Button(timer.isFinished ? "Zurücksetzen" : "Stopp") { self.timer = nil }
            } else {
                Button(
                    "Timer \(seconds >= 60 ? "\(seconds / 60) Min." : "\(seconds) Sek.")",
                    systemImage: "timer"
                ) {
                    timer = StepTimer(stepID: step.id, seconds: seconds)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var ingredientsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Zutaten")
                    .font(SousStyle.sectionHeading)
                ForEach(recipe.ingredientGroups(scaledToServings: servings), id: \.group) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        if let name = group.group {
                            Text(name)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group.ingredients) { ingredient in
                            Button {
                                toggle(ingredient.id)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: checkedIngredients.contains(ingredient.id)
                                        ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.tint)
                                    IngredientLineView(ingredient: ingredient, formatter: formatter)
                                        .strikethrough(checkedIngredients.contains(ingredient.id))
                                        .opacity(checkedIngredients.contains(ingredient.id) ? 0.45 : 1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity)
    }

    /// Leaving after the last step counts as having cooked the dish; leaving
    /// halfway through does not.
    private func finish() {
        if didReachLastStep {
            Task { await library.markCooked(recipe) }
        }
        dismiss()
    }

    /// Numbering restarts within a group, as its heading implies.
    private func number(for step: RecipeStep, at index: Int) -> Int {
        steps[...index].filter { $0.group == step.group }.count
    }

    private func isFirstOfGroup(_ step: RecipeStep) -> Bool {
        steps.first { $0.group == step.group }?.id == step.id
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
        String(format: "%d:%02d", remaining / 60, remaining % 60)
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
