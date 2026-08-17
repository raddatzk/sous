import SousKit
import SwiftUI

/// The days ahead, one after another: what is cooked when.
struct MealPlanView: View {
    @Environment(MealPlanLibrary.self) private var plan
    @Environment(ShoppingLibrary.self) private var shopping

    @State private var pickingDay: Date?
    @State private var openedRecipe: Recipe?

    var body: some View {
        NavigationStack {
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
                .navigationTitle("Essensplan")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar(scroll: scroll) }
            }
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
            // One quiet line, so an empty fortnight stays scrollable.
            Button {
                pickingDay = day
            } label: {
                Text("Nichts geplant")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contentShape(.rect)
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
            Button("Rezept einplanen", systemImage: "plus") { pickingDay = day }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .textCase(nil)
    }

    private func isToday(_ day: Date) -> Bool {
        Calendar.current.isDateInToday(day)
    }

    @ToolbarContentBuilder
    private func toolbar(scroll: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Heute") {
                withAnimation { scroll.scrollTo(plan.days.first, anchor: .top) }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu("Einkaufsliste", systemImage: "cart.badge.plus") {
                Button("Nächste 7 Tage") { addToShoppingList(days: 7) }
                Button("Nächste 14 Tage") { addToShoppingList(days: 14) }
            }
            .labelStyle(.iconOnly)
            .disabled(plan.plannedRecipes.isEmpty)
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
}

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}
