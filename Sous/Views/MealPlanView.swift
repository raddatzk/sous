import SousKit
import SwiftUI

/// The week ahead: which recipes are cooked on which day.
struct MealPlanView: View {
    @Environment(MealPlanLibrary.self) private var plan
    @Environment(RecipeLibrary.self) private var library
    @Environment(ShoppingLibrary.self) private var shopping

    @State private var pickingDay: Date?
    @State private var openedRecipe: Recipe?

    var body: some View {
        NavigationStack {
            List {
                ForEach(plan.days, id: \.self) { day in
                    Section {
                        dayContent(day)
                    } header: {
                        dayHeader(day)
                    }
                }
            }
            .navigationTitle(weekTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { weekToolbar }
            .task { await plan.reload() }
            .sheet(item: $pickingDay) { day in
                RecipePickerView(title: "Rezept einplanen", excluding: UUID()) { recipe in
                    Task { await plan.add(recipe, to: day) }
                }
            }
            .navigationDestination(item: $openedRecipe) { recipe in
                RecipeDetailView(recipe: recipe)
            }
        }
    }

    @ViewBuilder
    private func dayContent(_ day: Date) -> some View {
        let entries = plan.plan(for: day)

        if entries.isEmpty {
            Button {
                pickingDay = day
            } label: {
                Label("Rezept einplanen", systemImage: "plus")
                    .font(.callout)
                    .foregroundStyle(.tint)
            }
        } else {
            ForEach(entries, id: \.entry.id) { item in
                Group {
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
                }
                .contentShape(.rect)
                .onTapGesture { openedRecipe = item.recipe }
                .swipeActions {
                    Button("Entfernen", systemImage: "trash", role: .destructive) {
                        Task { await plan.remove(item.entry) }
                    }
                }
            }

            Button {
                pickingDay = day
            } label: {
                Label("Weiteres Rezept", systemImage: "plus")
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private func dayHeader(_ day: Date) -> some View {
        HStack {
            // `Text(date, format:)` follows the environment's locale;
            // `date.formatted()` always uses the system's.
            Text(day, format: .dateTime.weekday(.wide))
                .font(SousStyle.groupHeading)
                .foregroundStyle(isToday(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(day, format: .dateTime.day().month())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
    }

    private func isToday(_ day: Date) -> Bool {
        Calendar.current.isDateInToday(day)
    }

    private var weekTitle: String {
        guard let first = plan.days.first, let last = plan.days.last else { return "Essensplan" }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(.sous)
        return "\(first.formatted(style)) – \(last.formatted(style))"
    }

    @ToolbarContentBuilder
    private var weekToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Vorige Woche", systemImage: "chevron.left") {
                Task { await plan.showWeek(offset: -1) }
            }
            .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Nächste Woche", systemImage: "chevron.right") {
                Task { await plan.showWeek(offset: 1) }
            }
            .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .automatic) {
            Button("Heute") {
                Task { await plan.showCurrentWeek() }
            }
        }
        ToolbarItem(placement: .automatic) {
            Button("Woche auf die Einkaufsliste", systemImage: "cart.badge.plus") {
                Task {
                    await shopping.add(
                        planned: plan.plannedRecipes,
                        describing: "Woche"
                    )
                }
            }
            .labelStyle(.iconOnly)
            .disabled(plan.plannedRecipes.isEmpty)
        }
    }
}

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}
