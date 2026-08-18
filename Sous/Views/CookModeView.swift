import SousKit
import SwiftUI

/// Full-screen cooking: the steps scroll continuously with the current one in
/// focus, the full ingredient list is one swipe to the left, and the pots
/// currently on the hob are a tap apart along the bottom.
///
/// The view draws the session; it does not own it. Where the cook has got to
/// lives in ``CookSession``, so leaving to look something up and coming back
/// — or switching to the other recipe and back — returns to the same step
/// with the same things ticked off.
struct CookModeView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(CookTimerCenter.self) private var timers
    @Environment(CookSession.self) private var session
    #if os(macOS)
    /// Cooking is a window of its own here, and this closes it.
    @Environment(\.dismiss) private var dismiss
    #endif

    /// The recipes on the hob, looked up from the ids the session keeps.
    @State private var recipes: [UUID: Recipe] = [:]
    /// The step whose duration is being set, if the sheet is open.
    @State private var settingTimer: TimerDraft?
    @State private var isPicking = false
    @State private var isSettingServings = false
    /// A recipe about to be taken off the hob with a timer still running.
    @State private var confirmingFinish: UUID?

    private let formatter = QuantityFormatter(locale: .sous)

    var body: some View {
        VStack(spacing: 0) {
            // The Mac puts all of this in the title bar: the name and the step
            // as title and subtitle, "Fertig" as a toolbar button, and closing
            // to the red traffic light, which is what it is for.
            #if os(iOS)
            header
            Divider()
            #endif
            if let entry = session.activeEntry, let recipe = recipes[entry.recipeID] {
                pages(entry, recipe)
                    // A fresh page view per recipe: the swipe between steps
                    // and ingredients belongs to the recipe being cooked.
                    .id(entry.recipeID)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
            // Along the bottom on the phone, where the hand already is. The
            // Mac has no thumb resting there and a title bar going spare, so
            // the pots ride in it instead.
            #if os(iOS)
            Divider()
            switcher
            #endif
        }
        #if os(macOS)
        // No title: the chips in the toolbar name the recipe, and the window
        // keeps the name the scene gave it. The subtitle says how far along
        // the pot is, which the step numbers alone cannot.
        .navigationSubtitle(activeSubtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Fertig") {
                    if let entry = session.activeEntry { finish(entry) }
                }
                .disabled(session.activeEntry == nil)
            }
            ToolbarItem(placement: .principal) {
                CookSwitcherChips(
                    entries: session.entries,
                    titles: recipes.mapValues(\.title),
                    activeRecipeID: session.activeEntry?.recipeID,
                    onSelect: { session.show($0) },
                    presentation: .toolbar
                )
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Rezept dazunehmen", systemImage: "plus") { isPicking = true }
            }
            // A pot that turns out to be for four rather than two should not
            // need the cook to leave the kitchen. On the phone this hangs off
            // the header's serving count; here it needs a button of its own.
            if let entry = session.activeEntry, let recipe = activeRecipe {
                ToolbarItem(placement: .primaryAction) {
                    Button("\(entry.servings) Portionen", systemImage: "person.2") {
                        isSettingServings = true
                    }
                    // With the icon alone the count is invisible until the
                    // button is pressed — and it was taken out of the
                    // subtitle on the promise that this would show it.
                    .labelStyle(.titleAndIcon)
                    .popover(isPresented: $isSettingServings) {
                        servingsPopover(entry: entry, recipe: recipe)
                    }
                }
            }
        }
        #endif
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
                        recipeID: draft.recipeID,
                        recipeTitle: draft.recipeTitle
                    )
                }
            }
        }
        .sheet(isPresented: $isPicking) {
            CookAddSheet(excluding: Set(session.entries.map(\.recipeID))) { picked, servings in
                session.start(picked, servings: servings)
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
        // An alert rather than a confirmation dialog: the dialog drops its
        // cancel button on iOS 26, which would leave "take it off the hob"
        // as the only thing on screen to press.
        .alert(
            "Es läuft noch ein Timer für dieses Rezept.",
            isPresented: Binding(
                get: { confirmingFinish != nil },
                set: { if !$0 { confirmingFinish = nil } }
            )
        ) {
            Button("Weiterkochen", role: .cancel) { confirmingFinish = nil }
            Button("Trotzdem fertig", role: .destructive) {
                if let id = confirmingFinish, let entry = session.entry(for: id) {
                    complete(entry)
                }
                confirmingFinish = nil
            }
        } message: {
            Text("Der Timer wird mit dem Rezept beendet.")
        }
        #if os(macOS)
        // The last pot off the hob takes the window with it. Closed here
        // rather than by the main window noticing: that window can itself be
        // closed, and then nobody would be left to notice.
        .onChange(of: session.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
        #endif
        // The ids are the truth; the recipes behind them are fetched, and
        // refetched whenever something joins or leaves the hob.
        .task(id: session.entries.map(\.recipeID)) { await resolveRecipes() }
        .onAppear { keepDisplayAwake(true) }
        .onDisappear { keepDisplayAwake(false) }
    }

    // MARK: - Chrome

    private var activeRecipe: Recipe? {
        session.activeEntry.flatMap { recipes[$0.recipeID] }
    }

    /// Where the cook is, for the window's subtitle. Only the step — the
    /// servings are a toolbar button of their own, and saying the number in
    /// both places would be saying it twice.
    private var activeSubtitle: String {
        guard let entry = session.activeEntry, let recipe = activeRecipe else { return "" }
        return stepPosition(entry: entry, recipe: recipe)
    }

    #if os(iOS)
    @ViewBuilder
    private var header: some View {
        let entry = session.activeEntry
        let recipe = entry.flatMap { recipes[$0.recipeID] }
        HStack {
            Button("Fertig") {
                if let entry { finish(entry) }
            }
            .disabled(entry == nil)
            Spacer()
            VStack(spacing: 2) {
                Text(recipe?.title ?? "Kochen")
                    .font(.headline)
                    .lineLimit(1)
                if let entry, let recipe {
                    HStack(spacing: 4) {
                        Text("\(stepPosition(entry: entry, recipe: recipe)) ·")
                            .foregroundStyle(.secondary)
                        // The serving count is also the way to change it:
                        // a pot that turns out to be for four rather than two
                        // should not need the cook to leave the kitchen.
                        Button("\(entry.servings) Portionen") { isSettingServings = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                    .font(.caption)
                    .popover(isPresented: $isSettingServings) {
                        servingsPopover(entry: entry, recipe: recipe)
                    }
                }
            }
            Spacer()
            // Puts cook mode away without taking anything off the hob — the
            // band at the top of the app brings it back.
            Button("Kochsicht schließen", systemImage: "chevron.down") {
                session.isPresented = false
            }
            .labelStyle(.iconOnly)
        }
        .padding()
    }
    #endif

    private func stepPosition(entry: CookSessionEntry, recipe: Recipe) -> String {
        let steps = recipe.steps
        let focused = focusedStep(entry, steps: steps)
        let index = steps.firstIndex { $0.id == focused } ?? 0
        return "Schritt \(index + 1) von \(steps.count)"
    }

    /// Changing the servings mid-cook. Nothing is lost by it: scaling only
    /// rewrites the amounts, so ingredients already ticked off stay ticked.
    @ViewBuilder
    private func servingsPopover(entry: CookSessionEntry, recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: binding(entry, \.servings), in: Recipe.servingsRange) {
                Label("\(entry.servings) Portionen", systemImage: "person.2")
                    .font(.headline)
            }
            if entry.servings != recipe.servings {
                HStack {
                    Text("Geschrieben für \(recipe.servings).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Zurücksetzen") {
                        binding(entry, \.servings).wrappedValue = recipe.servings
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 260)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private var switcher: some View {
        CookSwitcherBar(
            entries: session.entries,
            titles: recipes.mapValues(\.title),
            activeRecipeID: session.activeEntry?.recipeID,
            onSelect: { session.show($0) },
            onAdd: { isPicking = true }
        )
    }

    @ViewBuilder
    private func pages(_ entry: CookSessionEntry, _ recipe: Recipe) -> some View {
        #if os(macOS)
        HStack(spacing: 0) {
            stepsPage(entry, recipe)
            Divider()
            ingredientsPage(entry, recipe).frame(width: 320)
        }
        #elseif os(iOS)
        TabView(selection: binding(entry, \.page)) {
            stepsPage(entry, recipe)
                .tag(CookSessionEntry.Page.steps)
            ingredientsPage(entry, recipe)
                .tag(CookSessionEntry.Page.ingredients)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        #endif
    }

    // MARK: - Steps

    /// All steps in one scroll, the focused one at full strength and the rest
    /// dimmed — the cook keeps their place without tapping anything.
    @ViewBuilder
    private func stepsPage(_ entry: CookSessionEntry, _ recipe: Recipe) -> some View {
        let steps = recipe.steps
        let focused = focusedStep(entry, steps: steps)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    stepCard(
                        step,
                        number: number(for: step, at: index, in: steps),
                        entry: entry,
                        recipe: recipe
                    )
                    .id(step.id)
                    .opacity(step.id == focused ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.2), value: focused)
                    .onTapGesture { focus(step.id, entry: entry, steps: steps) }
                }
                Color.clear.frame(height: 200)
            }
            .scrollTargetLayout()
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            // Centred in the rest. Capped and pinned left, the steps sat
            // against the window's edge with the width of a Mac window empty
            // beside them.
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: focusBinding(entry, steps: steps), anchor: .top)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func stepCard(
        _ step: RecipeStep,
        number: Int,
        entry: CookSessionEntry,
        recipe: Recipe
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let group = step.group, isFirstOfGroup(step, in: recipe.steps) {
                Text(group)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("\(number)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.tint)
                    .frame(minWidth: 44, alignment: .trailing)
                Text(markdown(recipe.scaledStepText(step, toServings: entry.servings)))
                    .font(.title3)
            }

            let used = recipe.ingredients(mentionedIn: step, scaledToServings: entry.servings)
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
                timerControl(step: step, seconds: seconds, number: number, recipe: recipe)
                    .padding(.leading, 60)
            }
        }
    }

    /// The timer on a step: the offer to start one, or the one that is
    /// running. Both, if it was started and the offer still makes sense.
    @ViewBuilder
    private func timerControl(
        step: RecipeStep,
        seconds: Int,
        number: Int,
        recipe: Recipe
    ) -> some View {
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
                        seconds: TimeInterval(seconds),
                        recipeID: recipe.id,
                        recipeTitle: recipe.title
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
                Text(timer.remaining(at: tick.date).cookTimerBadge)
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(finished ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Button(finished ? "Aus" : "Stopp") { timers.cancel(timer) }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// A timer about to be set: which step of which recipe, and what the
    /// recipe suggested.
    private struct TimerDraft: Identifiable {
        let stepID: UUID
        let stepNumber: Int
        let seconds: TimeInterval
        let recipeID: UUID
        let recipeTitle: String
        var id: UUID { stepID }
    }

    // MARK: - Ingredients

    @ViewBuilder
    private func ingredientsPage(_ entry: CookSessionEntry, _ recipe: Recipe) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Zutaten")
                    .font(SousStyle.sectionHeading)
                ForEach(recipe.ingredientGroups(scaledToServings: entry.servings), id: \.group) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        if let name = group.group {
                            Text(name)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group.ingredients) { ingredient in
                            let isChecked = entry.checkedIngredients.contains(ingredient.id)
                            Button {
                                toggle(ingredient.id, entry: entry)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.tint)
                                    IngredientLineView(ingredient: ingredient, formatter: formatter)
                                        .strikethrough(isChecked)
                                        .opacity(isChecked ? 0.45 : 1)
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
        // A window has to give the keyboard focus to something when it opens,
        // and the first thing here that can take it is the first ingredient's
        // tick box. In the app's own accent the ring around it reads as "this
        // one is selected", which is exactly what the tick box means and
        // exactly what has not happened.
        //
        // The effect goes, not the focusability: the boxes can still be
        // reached and pressed from the keyboard.
        .focusEffectDisabled()
    }

    // MARK: - Session

    private func resolveRecipes() async {
        var resolved: [UUID: Recipe] = [:]
        for entry in session.entries {
            if let recipe = await library.recipe(id: entry.recipeID), !recipe.isDeleted {
                resolved[entry.recipeID] = recipe
            }
        }
        recipes = resolved
        // A recipe deleted while it was on the hob cannot be cooked from.
        session.prune(toRecipes: Set(resolved.keys))
    }

    /// Takes a recipe off the hob — asking first if something is still
    /// counting down, because a timer whose recipe is gone would ring for
    /// nothing.
    private func finish(_ entry: CookSessionEntry) {
        let running = timers.timers(forRecipe: entry.recipeID)
        if running.contains(where: { !$0.isFinished() }) {
            confirmingFinish = entry.recipeID
        } else {
            complete(entry)
        }
    }

    /// Cooking through to the last step counts as having cooked the dish;
    /// leaving halfway through does not.
    private func complete(_ entry: CookSessionEntry) {
        if entry.didReachLastStep, let recipe = recipes[entry.recipeID] {
            Task { await library.markCooked(recipe) }
        }
        for timer in timers.timers(forRecipe: entry.recipeID) {
            timers.cancel(timer)
        }
        session.remove(entry.recipeID)
    }

    /// Writes one field of an entry back into the session.
    private func binding<Value>(
        _ entry: CookSessionEntry,
        _ keyPath: WritableKeyPath<CookSessionEntry, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (session.entry(for: entry.recipeID) ?? entry)[keyPath: keyPath] },
            set: { newValue in
                guard var current = session.entry(for: entry.recipeID) else { return }
                current[keyPath: keyPath] = newValue
                session.update(current)
            }
        )
    }

    /// The step the scroll view keeps in view.
    ///
    /// Reads through ``focusedStep(_:steps:)`` rather than the stored value,
    /// so a recipe edited between two sessions — which gives its steps new
    /// ids — starts at the top instead of pointing at nothing. Writes of
    /// `nil` are dropped: the scroll view reports one while it is settling,
    /// and taking it at face value would forget where the cook is.
    private func focusBinding(_ entry: CookSessionEntry, steps: [RecipeStep]) -> Binding<UUID?> {
        Binding(
            get: { focusedStep(entry, steps: steps) },
            set: { newValue in
                guard let newValue else { return }
                focus(newValue, entry: entry, steps: steps)
            }
        )
    }

    private func focus(_ stepID: UUID, entry: CookSessionEntry, steps: [RecipeStep]) {
        guard var current = session.entry(for: entry.recipeID) else { return }
        current.focusedStepID = stepID
        if stepID == steps.last?.id { current.didReachLastStep = true }
        session.update(current)
    }

    private func focusedStep(_ entry: CookSessionEntry, steps: [RecipeStep]) -> UUID? {
        let stored = session.entry(for: entry.recipeID)?.focusedStepID
        return steps.contains { $0.id == stored } ? stored : steps.first?.id
    }

    private func toggle(_ id: UUID, entry: CookSessionEntry) {
        guard var current = session.entry(for: entry.recipeID) else { return }
        if current.checkedIngredients.contains(id) {
            current.checkedIngredients.remove(id)
        } else {
            current.checkedIngredients.insert(id)
        }
        session.update(current)
    }

    // MARK: - Helpers

    /// Numbering restarts within a group, as its heading implies.
    private func number(for step: RecipeStep, at index: Int, in steps: [RecipeStep]) -> Int {
        steps[...index].filter { $0.group == step.group }.count
    }

    private func isFirstOfGroup(_ step: RecipeStep, in steps: [RecipeStep]) -> Bool {
        steps.first { $0.group == step.group }?.id == step.id
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
