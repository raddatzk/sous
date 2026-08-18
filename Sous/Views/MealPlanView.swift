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
    @Environment(ShoppingLibrary.self) private var shopping

    /// Remembered across launches: whichever way a cook plans, they keep
    /// planning that way.
    @AppStorage("mealPlanMode") private var mode: PlanMode = .calendar

    @State private var pickingSlot: PlannedSlot?
    @State private var isPickingForPool = false
    @State private var movingEntry: MealPlanEntry?
    @State private var openedRecipe: Recipe?

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modePicker
                content
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
            .navigationDestination(item: $openedRecipe) { recipe in
                RecipeDetailView(recipe: recipe)
            }
        }
    }

    @ViewBuilder
    private var modePicker: some View {
        Picker("Ansicht", selection: $mode) {
            Text(PlanMode.calendar.title).tag(PlanMode.calendar)
            Text(PlanMode.pool.title).tag(PlanMode.pool)
        }
        .pickerStyle(.segmented)
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
        ScrollViewReader { scroll in
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
            .toolbar { calendarToolbar(scroll: scroll) }
        }
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
                        .swipeActions {
                            Button("Entfernen", systemImage: "trash", role: .destructive) {
                                Task { await plan.remove(item.entry) }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("In die Sammlung", systemImage: "tray") {
                                Task { await plan.move(item.entry, to: nil) }
                            }
                            .tint(.orange)
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
                    .swipeActions {
                        Button("Entfernen", systemImage: "trash", role: .destructive) {
                            Task { await plan.remove(item.entry) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Auf einen Tag", systemImage: "calendar") {
                            movingEntry = item.entry
                        }
                        .tint(.accentColor)
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
    private func mealRow(_ item: (entry: MealPlanEntry, recipe: Recipe?)) -> some View {
        HStack(spacing: 12) {
            if let imageID = item.recipe?.imageIDs.first {
                RecipeImageView(imageID: imageID, thumbnail: true)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.recipe?.title ?? "Gelöschtes Rezept")
                    .font(SousStyle.recipeName)
                Text("\(item.entry.servings ?? item.recipe?.servings ?? 0) Portionen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(.rect)
        .onTapGesture { openedRecipe = item.recipe }
    }

    @ToolbarContentBuilder
    private func calendarToolbar(scroll: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Heute") {
                withAnimation { scroll.scrollTo(plan.days.first, anchor: .top) }
            }
        }
        shoppingListButton
    }

    @ToolbarContentBuilder
    private var poolToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Gericht vormerken", systemImage: "plus") { isPickingForPool = true }
        }
        shoppingListButton
    }

    @ToolbarContentBuilder
    private var shoppingListButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("Einkaufsliste", systemImage: "cart.badge.plus") {
                Button("Nächste 7 Tage") { addToShoppingList(days: 7) }
                Button("Nächste 14 Tage") { addToShoppingList(days: 14) }
                if !plan.pool.isEmpty {
                    Divider()
                    Button("Alles aus der Sammlung") { addPoolToShoppingList() }
                }
            }
            .labelStyle(.iconOnly)
            .disabled(plan.entries.isEmpty && plan.pool.isEmpty)
        }
    }

    private func addToShoppingList(days: Int) {
        guard let start = plan.days.first,
              let end = Calendar.current.date(byAdding: .day, value: days - 1, to: start)
        else { return }

        Task {
            await shopping.add(
                planned: plan.plannedRecipes(from: start, through: end),
                describing: "Essensplan"
            )
        }
    }

    private func addPoolToShoppingList() {
        Task {
            await shopping.add(planned: plan.pooledRecipes, describing: "Sammlung")
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
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #elseif os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}

