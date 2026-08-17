import SousKit
import SwiftUI

/// Puts a recipe on a day of the meal plan.
struct PlanRecipeSheet: View {
    @Environment(MealPlanLibrary.self) private var plan
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe
    /// The serving count the reader had chosen, offered as the default.
    let servings: Int

    @State private var day = Date()
    @State private var slot: MealSlot = .dinner
    @State private var plannedServings: Int

    init(recipe: Recipe, servings: Int) {
        self.recipe = recipe
        self.servings = servings
        _plannedServings = State(initialValue: servings)
    }

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

                Section {
                    Stepper(value: $plannedServings, in: 1...50) {
                        Label("\(plannedServings) Portionen", systemImage: "person.2")
                    }
                } footer: {
                    if plannedServings != recipe.servings {
                        Text("Das Rezept ist für \(recipe.servings) Portionen geschrieben; die Mengen werden umgerechnet.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(recipe.title)
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
                            await plan.add(recipe, to: day, slot: slot, servings: plannedServings)
                            dismiss()
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
    }
}
