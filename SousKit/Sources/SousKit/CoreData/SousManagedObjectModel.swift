import CoreData
import Foundation

/// The Core Data schema for everything that belongs to a household.
///
/// Written in code rather than as an `.xcdatamodeld`, for two reasons. SousKit
/// is a Swift package, where a model bundle is a resource to be found at
/// runtime and a source of failures that only appear once the app is
/// assembled; and a schema this flat reads better as a list of fields than as
/// an XML file nobody can review in a diff.
///
/// Every attribute is optional or carries a default and there is not one
/// relationship in here. That is not a style preference: CloudKit mirroring
/// requires it, and the SwiftData models this mirrors were already written
/// that way — ingredients and instructions are text, group membership is a
/// plain id, images are referenced by id. The port is cheap precisely because
/// there is no object graph to reproduce.
///
/// What is deliberately *not* here yet is the household reference. It belongs
/// on every row once libraries live in shared zones, but a field nothing
/// writes and nothing reads is dead weight in the meantime, and adding an
/// optional attribute later is a lightweight migration — free while no data
/// has reached anyone's iCloud.
enum SousManagedObjectModel {
    /// Built once. `NSManagedObjectModel` instances are not cheap and Core
    /// Data warns when two of them describe the same entities in one process.
    ///
    /// `nonisolated(unsafe)` because the type predates `Sendable` and cannot
    /// declare what is nonetheless true of it: a model becomes immutable the
    /// moment a coordinator takes it, and nothing here writes to it after the
    /// closure returns.
    nonisolated(unsafe) static let shared: NSManagedObjectModel = {
        let model = NSManagedObjectModel()
        model.entities = [recipeEntity(), variantGroupEntity()]
        return model
    }()

    static let recipeEntityName = "CDRecipe"
    static let variantGroupEntityName = "CDVariantGroup"

    private static func recipeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = recipeEntityName
        entity.managedObjectClassName = NSStringFromClass(CDRecipe.self)
        entity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("title", .stringAttributeType, default: ""),
            attribute("summary", .stringAttributeType, optional: true),
            attribute("servings", .integer64AttributeType, default: 2),
            attribute("ingredientsText", .stringAttributeType, default: ""),
            attribute("instructionsText", .stringAttributeType, default: ""),
            // The list-valued fields are JSON in a string rather than
            // transformable blobs: they are read back as whole lists and never
            // queried against, a string survives every CloudKit record type
            // without a value transformer to register on both platforms, and
            // it is legible when someone opens the store with sqlite3.
            attribute("categoriesJSON", .stringAttributeType, default: "[]"),
            attribute("isFavorite", .booleanAttributeType, default: false),
            attribute("wantToCook", .booleanAttributeType, default: false),
            attribute("notes", .stringAttributeType, optional: true),
            attribute("sourceKind", .stringAttributeType, default: RecipeSource.Kind.manual.rawValue),
            attribute("sourceURL", .stringAttributeType, optional: true),
            attribute("sourceName", .stringAttributeType, optional: true),
            attribute("prepTimeSeconds", .integer64AttributeType, optional: true),
            attribute("cookTimeSeconds", .integer64AttributeType, optional: true),
            attribute("totalTimeSeconds", .integer64AttributeType, optional: true),
            attribute("imageIDsJSON", .stringAttributeType, default: "[]"),
            // Optional rather than empty-by-default: nobody having chosen a
            // slot is a different statement from every slot being unsuitable,
            // and the domain type keeps that distinction as an optional Set.
            attribute("suitableSlotsJSON", .stringAttributeType, optional: true),
            attribute("variantGroupID", .UUIDAttributeType, optional: true),
            attribute("createdBy", .UUIDAttributeType, optional: true),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("deletedAt", .dateAttributeType, optional: true),
            attribute("searchText", .stringAttributeType, default: ""),
            attribute("ingredientKeysJSON", .stringAttributeType, default: "[]"),
        ]
        // The same two indexes the SwiftData model declares: the list sorts by
        // title and the sync sorts by when a row last changed.
        entity.indexes = [
            index(named: "byTitle", on: entity, properties: ["title"]),
            index(named: "byUpdatedAt", on: entity, properties: ["updatedAt"]),
            index(named: "byID", on: entity, properties: ["id"]),
        ]
        return entity
    }

    private static func variantGroupEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = variantGroupEntityName
        entity.managedObjectClassName = NSStringFromClass(CDVariantGroup.self)
        entity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("title", .stringAttributeType, default: ""),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
        ]
        entity.indexes = [index(named: "byID", on: entity, properties: ["id"])]
        return entity
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false,
        default defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        // CloudKit requires every attribute to be optional or to carry a
        // default. Where neither is stated here the field is one the store
        // always writes on insert — an id, a timestamp — and marking it
        // optional would only move the failure from the compiler to a nil
        // nobody expected.
        attribute.isOptional = optional || defaultValue == nil
        attribute.defaultValue = defaultValue
        return attribute
    }

    private static func index(
        named name: String,
        on entity: NSEntityDescription,
        properties: [String]
    ) -> NSFetchIndexDescription {
        let elements = properties.compactMap { propertyName -> NSFetchIndexElementDescription? in
            guard let property = entity.properties.first(where: { $0.name == propertyName }) else { return nil }
            return NSFetchIndexElementDescription(property: property, collationType: .binary)
        }
        return NSFetchIndexDescription(name: name, elements: elements)
    }
}
