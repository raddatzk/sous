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
    @Test("The library puts the built-in ones first, keeps its own in order and drops empty ones")
    func library() async {
        let library = PromptTemplateLibrary()
        await library.reload()
        #expect(library.all == PromptTemplate.builtIn)

        await library.save(PromptTemplate(title: "A", text: "Erstens"))
        await library.save(PromptTemplate(title: "B", text: "Zweitens"))
        await library.save(PromptTemplate(title: "  ", text: "ohne Titel"))
        #expect(library.own.map(\.title) == ["A", "B"])
        #expect(library.all.count == PromptTemplate.builtIn.count + 2)

        await library.delete(library.own[0])
        #expect(library.own.map(\.title) == ["B"])
    }

    @Test("Every built-in template tells where the recipe goes")
    func builtIns() {
        #expect(PromptTemplate.builtIn.allSatisfy { $0.text.contains(RecipeReplacementPrompt.placeholder) })
        #expect(Set(PromptTemplate.builtIn.map(\.id)).count == PromptTemplate.builtIn.count)
    }
}
