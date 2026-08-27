import SousKit
import SwiftUI

/// The meal plan, in either of the two ways it gets used.
///
/// **Kalender** is the plan proper: what is cooked on which day. **Sammlung**
/// is the same plan without the dates — meals decided on but not pinned to an
/// evening, which is how planning usually survives contact with a week.
/// Entries move between the two without being re-entered.
struct MealPlanView: View {
    @Environment(MealPlanLibrary.self) private var plan

    /// Remembered across launches: whichever way a cook plans, they keep
    /// planning that way.
    @AppStorage("mealPlanMode") private var mode: PlanMode = .calendar

    @State private var pickingSlot: PlannedSlot?
    @State private var isPickingForPool = false
    @State private var movingEntry: MealPlanEntry?
    @State private var openedRecipe: OpenedRecipe?
    @State private var isPlanning = false

    enum PlanMode: String {
        case calendar
        case pool

        var title: String {
            switch self {
            case .calendar: "Kalender"
            case .pool: "Sammlung"
            }
        }
    }

    /// A day and the meal being planned for it.
    private struct PlannedSlot: Identifiable {
        let day: Date
        let slot: MealSlot
        var id: String { "\(day.timeIntervalSince1970)-\(slot.rawValue)" }
    }

    /// A recipe opened from the plan, carrying which entry it came from —
    /// the detail view derives its serving scale from that, not a count
    /// captured at the moment of opening.
    private struct OpenedRecipe: Identifiable, Hashable {
        let recipe: Recipe
        let entryID: MealPlanEntry.ID
        var id: Recipe.ID { recipe.id }
    }

    @Environment(RecipeSelection.self) private var selection

    var body: some View {
        // The Mac has one split view for the whole window, so this is only
        // its first column; the phone brings its own stack and pushes.
        #if os(macOS)
        planColumn
        #else
        NavigationStack {
            planColumn
                .navigationDestination(item: $openedRecipe) { opened in
                    RecipeDetailView(recipe: opened.recipe, plannedEntryID: opened.entryID)
                }
        }
        #endif
    }

    @ViewBuilder
    private var planColumn: some View {
        // The reader wraps both, so the row above the list can scroll it.
        ScrollViewReader { scroll in
            VStack(spacing: 0) {
                modeRow(scroll: scroll)
                content
            }
        }
        .navigationTitle("Essensplan")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await plan.reload() }
        .sheet(item: $pickingSlot) { target in
            RecipePickerView(
                title: "\(target.slot.title) einplanen",
                excluding: UUID()
            ) { recipe in
                Task { await plan.add(recipe, to: target.day, slot: target.slot) }
            }
        }
        .sheet(isPresented: $isPickingForPool) {
            RecipePickerView(title: "In die Sammlung", excluding: UUID()) { recipe in
                Task { await plan.add(recipe, to: nil) }
            }
        }
        .sheet(item: $movingEntry) { entry in
            MoveToDaySheet(entry: entry, title: plan.recipes[entry.recipeID]?.title ?? "Gericht")
        }
        .sheet(isPresented: $isPlanning) {
            // The proposal's default destination follows the door: the
            // calendar plans onto days, the Sammlung into itself.
            PlanDinnersSheet(defaultMode: mode == .calendar ? .days : .pool)
        }
    }

    /// Which of the two views, and — in the calendar — the way back to today.
    ///
    /// One row rather than two: "Heute" is a single small button and had a
    /// line of its own above the days, which is a lot of chrome for one word.
    @ViewBuilder
    private func modeRow(scroll: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            Picker("Ansicht", selection: $mode) {
                Text(PlanMode.calendar.title).tag(PlanMode.calendar)
                Text(PlanMode.pool.title).tag(PlanMode.pool)
            }
            .pickerStyle(.segmented)
            // macOS shows a segmented picker's label; iOS hides it. Without
            // this the word "Ansicht" sits in front of the two choices.
            .labelsHidden()
            .frame(maxWidth: 320)

            if mode == .calendar {
                Button("Heute") {
                    withAnimation { scroll.scrollTo(plan.days.first, anchor: .top) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .calendar: calendar
        case .pool: poolList
        }
    }

    // MARK: - Calendar

    @ViewBuilder
    private var calendar: some View {
        List {
            ForEach(plan.days, id: \.self) { day in
                Section {
                    dayContent(day)
                } header: {
                    dayHeader(day)
                }
                .id(day)
            }

            // Reaching the end simply adds more days rather than
            // stopping at a boundary.
            Color.clear
                .frame(height: 1)
                .listRowSeparator(.hidden)
                .onAppear { Task { await plan.loadMore() } }
        }
        .toolbar { calendarToolbar }
    }

    @ViewBuilder
    private func dayContent(_ day: Date) -> some View {
        let meals = plan.meals(for: day)

        if meals.isEmpty {
            // One quiet line, so an empty fortnight stays scrollable.
            Menu {
                slotButtons(for: day)
            } label: {
                Text("Nichts geplant")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            ForEach(meals, id: \.slot) { meal in
                Label(meal.slot.title, systemImage: meal.slot.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)

                ForEach(meal.items, id: \.entry.id) { item in
                    mealRow(item)
                        .swipeActions { removeAction(item.entry) }
                        .swipeActions(edge: .leading) {
                            toPoolAction(item.entry).tint(.orange)
                        }
                        // Both again as a menu: a swipe needs a trackpad to
                        // exist at all, and nothing on the row says it does.
                        .contextMenu {
                            toPoolAction(item.entry)
                            removeAction(item.entry)
                        }
                }
            }
        }
    }

    /// One button per meal, for choosing where a recipe goes.
    @ViewBuilder
    private func slotButtons(for day: Date) -> some View {
        ForEach(MealSlot.allCases, id: \.self) { slot in
            Button(slot.title, systemImage: slot.symbolName) {
                pickingSlot = PlannedSlot(day: day, slot: slot)
            }
        }
    }

    @ViewBuilder
    private func dayHeader(_ day: Date) -> some View {
        HStack {
            Text(day, format: .dateTime.weekday(.wide))
                .font(SousStyle.groupHeading)
                .foregroundStyle(isToday(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(day, format: .dateTime.day().month())
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                slotButtons(for: day)
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(.tint)
            }
        }
        .textCase(nil)
    }

    private func isToday(_ day: Date) -> Bool {
        Calendar.current.isDateInToday(day)
    }

    // MARK: - Pool

    @ViewBuilder
    private var poolList: some View {
        List {
            ForEach(plan.pooledMeals, id: \.entry.id) { item in
                mealRow(item)
                    .swipeActions { removeAction(item.entry) }
                    .swipeActions(edge: .leading) {
                        toDayAction(item.entry).tint(.accentColor)
                    }
                    .contextMenu {
                        toDayAction(item.entry)
                        removeAction(item.entry)
                    }
            }
        }
        .overlay {
            if plan.pool.isEmpty {
                ContentUnavailableView {
                    Label("Nichts vorgemerkt", systemImage: "tray")
                } description: {
                    Text("Gerichte ohne festen Tag sammeln sich hier — gekocht wird, worauf gerade Lust ist.")
                } actions: {
                    Button("Gericht vormerken") { isPickingForPool = true }
                }
            }
        }
        .toolbar { poolToolbar }
    }

    // MARK: - Shared parts

    @ViewBuilder
    private func removeAction(_ entry: MealPlanEntry) -> some View {
        Button("Entfernen", systemImage: "trash", role: .destructive) {
            Task { await plan.remove(entry) }
        }
    }

    @ViewBuilder
    private func toPoolAction(_ entry: MealPlanEntry) -> some View {
        Button("In die Sammlung", systemImage: "tray") {
            Task { await plan.move(entry, to: nil) }
        }
    }

    @ViewBuilder
    private func toDayAction(_ entry: MealPlanEntry) -> some View {
        Button("Auf einen Tag", systemImage: "calendar") {
            movingEntry = entry
        }
    }

    @ViewBuilder
    private func mealRow(_ item: (entry: MealPlanEntry, recipe: Recipe?)) -> some View {
        // A button rather than a tap gesture: the pointer changes over it,
        // the keyboard reaches it, and the Mac gets the click it expects.
        Button {
            open(item)
        } label: {
            HStack(spacing: 12) {
                if let imageID = item.recipe?.imageIDs.first {
                    RecipeImageView(imageID: imageID, thumbnail: true)
                        .frame(width: 44, height: 44)
                        .clipShape(.rect(cornerRadius: 8))
                }
                Text(item.recipe?.title ?? "Gelöschtes Rezept")
                    .font(SousStyle.recipeName)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isOpen(item) ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 8)
        )
        #endif
    }

    private func open(_ item: (entry: MealPlanEntry, recipe: Recipe?)) {
        guard let recipe = item.recipe else { return }
        #if os(macOS)
        selection.recipe = recipe
        selection.plannedEntryID = item.entry.id
        #else
        openedRecipe = OpenedRecipe(recipe: recipe, entryID: item.entry.id)
        #endif
    }

    #if os(macOS)
    /// Whether this row is the one the detail column is showing — the only
    /// way to tell, since the split view keeps both on screen at once.
    private func isOpen(_ item: (entry: MealPlanEntry, recipe: Recipe?)) -> Bool {
        selection.plannedEntryID == item.entry.id
    }
    #endif

    @ToolbarContentBuilder
    private var calendarToolbar: some ToolbarContent {
        planButton
    }

    @ToolbarContentBuilder
    private var poolToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Gericht vormerken", systemImage: "plus") { isPickingForPool = true }
        }
        planButton
    }

    /// Always enabled: the sheet itself explains when there is nothing to
    /// plan, which beats a mysteriously grey wand.
    @ToolbarContentBuilder
    private var planButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Essen planen", systemImage: "wand.and.stars") { isPlanning = true }
                .labelStyle(.iconOnly)
                .help("Essen planen")
        }
    }
}

/// Puts a meal that was floating in the pool onto a day.
private struct MoveToDaySheet: View {
    @Environment(MealPlanLibrary.self) private var plan
    @Environment(\.dismiss) private var dismiss

    let entry: MealPlanEntry
    let title: String

    @State private var day = Date()
    @State private var slot: MealSlot = .dinner

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Tag", selection: $day, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                Section {
                    Picker("Mahlzeit", selection: $slot) {
                        ForEach(MealSlot.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Einplanen") {
                        Task {
                            await plan.move(entry, to: day, slot: slot)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { slot = entry.slot }
        }
        .sousSheetSizing(.form)
    }
}

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}

