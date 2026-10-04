import CoreData
import Foundation
import Testing
@testable import SousKit

@Suite("A household's prompt templates")
struct PromptTemplateTests {
    @Test("Core Data keeps them per household, upserts by id and deletes")
    func store() async throws {
        let container = try SousPersistentContainer.make(inMemory: true)
        let store = CoreDataPromptTemplateStore(container: container)
        var template = PromptTemplate(title: "Vegan", text: "Mach es vegan. {{recipe}}")
        try await store.save(template)
        template.text = "Mach es vegan und proteinreich. {{recipe}}"
        try await store.save(template)

        let read = try await store.templates()
        #expect(read.count == 1)
        #expect(read.first?.text == "Mach es vegan und proteinreich. {{recipe}}")

        try await store.delete(id: template.id)
        #expect(try await store.templates().isEmpty)
    }

    @MainActor
    @Test("Built-in templates can be changed, taken away and restored like the household's own")
    func library() async {
        let library = PromptTemplateLibrary()
        await library.reload()
        #expect(library.all == PromptTemplate.builtIn)
        #expect(!library.hasChangedBuiltIns)

        // Changed: takes the built-in one's place.
        var vegan = library.all[0]
        vegan.text = "Mach es vegan und proteinreich. {{recipe}}"
        await library.save(vegan)
        #expect(library.all.count == PromptTemplate.builtIn.count)
        #expect(library.all[0].text == "Mach es vegan und proteinreich. {{recipe}}")
        #expect(library.hasChangedBuiltIns)

        // Taken away: gone from the list, and stays gone.
        let four = library.all.first { $0.title == "Für vier Personen" }!
        await library.delete(four)
        #expect(!library.all.contains { $0.id == four.id })

        // One of their own comes after the built-in ones, in order; empty ones are not kept.
        await library.save(PromptTemplate(title: "A", text: "Erstens"))
        await library.save(PromptTemplate(title: "B", text: "Zweitens"))
        await library.save(PromptTemplate(title: "  ", text: "ohne Titel"))
        #expect(library.all.suffix(2).map(\.title) == ["A", "B"])
        await library.delete(library.all.last!)
        #expect(library.all.last?.title == "A")

        // Back to the defaults; their own stay.
        await library.restoreBuiltIns()
        #expect(Array(library.all.prefix(PromptTemplate.builtIn.count)) == PromptTemplate.builtIn)
        #expect(library.all.last?.title == "A")
        #expect(!library.hasChangedBuiltIns)
    }

    @Test("The preview leaves the placeholder out")
    func preview() {
        let template = PromptTemplate(title: "T", text: "Mach es vegan.\n\n{{recipe}}")
        #expect(template.preview == "Mach es vegan.")
    }

    @Test("Every built-in template tells where the recipe goes")
    func builtIns() {
        #expect(PromptTemplate.builtIn.allSatisfy { $0.text.contains(RecipeReplacementPrompt.placeholder) })
        #expect(Set(PromptTemplate.builtIn.map(\.id)).count == PromptTemplate.builtIn.count)
    }
}
