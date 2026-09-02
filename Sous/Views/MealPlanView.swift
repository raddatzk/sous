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

    /// Below this the plan and a recipe stop fitting beside each other, and a
    /// tapped meal opens as a page of its own instead.
    ///
    /// Derived rather than picked. The day rows need 380 — the width the
    /// Mac's column settled on, after 320 left the weekday, the date and the
    /// menu that adds a meal fighting over one line — and the recipe page
    /// needs 740 to keep its own two columns rather than being squeezed back
    /// into one. The sum lands between an iPad's two ways up: every iPad,
    /// from the mini to the 13-inch, is under it in portrait and over it in
    /// landscape, which is the shape this was asked for. Measured rather than
    /// asked of the orientation, so a wide shared window gets it too and a
    /// narrow one does not.
    private static let splitWidth: CGFloat = 1120
    private static let planWidth: CGFloat = 380

    var body: some View {
        // The Mac has one split view for the whole window, so this is only
        // its first column.
        #if os(macOS)
        planColumn
        #else
        GeometryReader { screen in
            if screen.size.width >= Self.splitWidth {
                // Planning a week is a back and forth between the plan and
                // the recipe being considered for it, and pushing a page over
                // the plan loses the place in the week on every look. Beside
                // it, the week stays put while the recipes change.
                NavigationSplitView {
                    planColumn
                        .navigationSplitViewColumnWidth(
                            min: Self.planWidth, ideal: 420, max: 560
                        )
                        // No way to collapse the column, for the reason the
                        // Mac's window gives: it is the only way to another
                        // meal. Collapsed, the tab is a recipe with no plan
                        // to get back to — and the tab bar cannot help,
                        // since this *is* the tab. On the column rather than
                        // on the split view: the button belongs to the bar
                        // the first column brings, and asking the split view
                        // to drop it left it sitting there.
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    openedDetail
                }
                // Both columns at once. The plan is the reason this screen
                // exists; an overlaid sidebar would put it behind a button.
                .navigationSplitViewStyle(.balanced)
            } else {
                // The phone's shape, and the iPad's upright: one column, and
                // a tapped meal pushes over it.
                NavigationStack {
                    planColumn
                        .navigationDestination(item: $openedRecipe) { opened in
                            RecipeDetailView(
                                recipe: opened.recipe, plannedEntryID: opened.entryID
                            )
                        }
                }
            }
        }
        #endif
    }

    #if os(iOS)
    /// What stands beside the plan: the meal last opened from it, or the
    /// reason there is nothing there yet.
    ///
    /// The selection belongs to this tab rather than to the app. A tab is a
    /// place you leave and come back to, and coming back to the shopping list
    /// to find a recipe from twenty minutes ago still open beside it would be
    /// a leftover rather than a context — which is the difference between
    /// three tabs and the Mac's one window with a switch in it.
    @ViewBuilder
    private var openedDetail: some View {
        if let opened = openedRecipe {
            RecipeDetailView(recipe: opened.recipe, plannedEntryID: opened.entryID)
        } else {
            ContentUnavailableView(
                "Kein Gericht ausgewählt",
                systemImage: "calendar",
                description: Text("Wähle links ein geplantes Gericht aus.")
            )
        }
    }
    #endif

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
        .sousErrorAlert(plan)
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

    /// Which of the two the plan is showing.
    ///
    /// The list style is left to the platform on purpose, though it means the
    /// week wears two skins: inset-grouped cards standing in a tab, flat
    /// sidebar rows standing in a split view's first column.
    ///
    /// Forcing the card look into the column was tried and given up. A first
    /// column is drawn at the elevated interface level, where
    /// `systemGroupedBackground` and the row's own colour swap places — so
    /// `.insetGrouped` there produced grey cards on white, the two tones of
    /// the upright plan exactly the wrong way round. Naming both colours by
    /// hand would mean compensating for that swap here and not on the phone,
    /// in both schemes, against a system rule that is not ours to keep. A
    /// skin that changes with the shape is the smaller price.
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
        .sousReadableList()
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
                            toPoolAction(item.entry).tint(Color.sousCaution)
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
                        toDayAction(item.entry).tint(Color.sousAccent)
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
        .sousReadableList()
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
                        .clipShape(.rect(cornerRadius: SousStyle.thumbnailRadius))
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
            in: .rect(cornerRadius: SousStyle.fieldRadius)
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

