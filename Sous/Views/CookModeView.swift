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
    @Environment(CookTimerCenter.self) private var timers
    /// The step whose duration is being set, if the sheet is open.
    @State private var settingTimer: TimerDraft?

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
        .sheet(item: $settingTimer) { draft in
            TimerSetupSheet(
                stepNumber: draft.stepNumber,
                suggested: draft.seconds
            ) { seconds in
                Task {
                    await timers.start(
                        seconds: seconds,
                        stepID: draft.stepID,
                        stepNumber: draft.stepNumber,
                        recipeTitle: recipe.title
                    )
                }
            }
        }
        .alert(
            "Timer",
            isPresented: Binding(
                get: { timers.errorMessage != nil },
                set: { if !$0 { timers.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { timers.errorMessage = nil }
        } message: {
            Text(timers.errorMessage ?? "")
        }
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
                timerControl(step: step, seconds: seconds, number: number)
                    .padding(.leading, 60)
            }
        }
    }

    /// The timer on a step: the offer to start one, or the one that is
    /// running. Both, if it was started and the offer still makes sense.
    @ViewBuilder
    private func timerControl(step: RecipeStep, seconds: Int, number: Int) -> some View {
        let running = timers.timers(forStep: step.id)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(running) { timer in
                runningTimer(timer)
            }
            if running.isEmpty {
                Button("Timer \(TimeInterval(seconds).cookTimerLabel)", systemImage: "timer") {
                    settingTimer = TimerDraft(
                        stepID: step.id,
                        stepNumber: number,
                        seconds: TimeInterval(seconds)
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// A countdown, redrawn every second while it runs.
    ///
    /// The seconds come from the end time rather than a stored count, so a
    /// screen that was off for a minute comes back a minute further along.
    @ViewBuilder
    private func runningTimer(_ timer: CookTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let finished = timer.isFinished(at: tick.date)
            HStack(spacing: 12) {
                Image(systemName: finished ? "bell.fill" : "timer")
                    .foregroundStyle(finished ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .symbolEffect(.pulse, isActive: finished)
                Text(countdown(timer, at: tick.date))
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(finished ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Button(finished ? "Aus" : "Stopp") { timers.cancel(timer) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func countdown(_ timer: CookTimer, at now: Date) -> String {
        let total = Int(timer.remaining(at: now).rounded())
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// A timer about to be set: which step, and what the recipe suggested.
    private struct TimerDraft: Identifiable {
        let stepID: UUID
        let stepNumber: Int
        let seconds: TimeInterval
        var id: UUID { stepID }
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
