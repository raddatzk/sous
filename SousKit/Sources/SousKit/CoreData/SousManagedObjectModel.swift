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
        let household = householdEntity()
        let members = [
            recipeEntity(), variantGroupEntity(), recipeImageEntity(), mealPlanEntryEntity(),
            reviewMarkEntity(named: amountReviewEntityName),
            reviewMarkEntity(named: ingredientReviewEntityName),
            vocabularyEntryEntity(),
            shoppingEntryEntity(), shoppingPlanEntryEntity(), shoppingDemandEntity(),
        ]
        // Wired after the fact, because a relationship needs both entities to
        // exist before either can name the other.
        link(members, to: household)
        model.entities = [household] + members
        return model
    }()

    static let householdEntityName = "CDHousehold"

    /// Every entity that belongs to a household, for the passes that have to
    /// walk all of them.
    static let memberEntityNames = [
        recipeEntityName, variantGroupEntityName, recipeImageEntityName,
        mealPlanEntryEntityName, amountReviewEntityName, ingredientReviewEntityName,
        vocabularyEntryEntityName, shoppingEntryEntityName,
        shoppingPlanEntryEntityName, shoppingDemandEntityName,
    ]
    static let recipeEntityName = "CDRecipe"
    static let variantGroupEntityName = "CDVariantGroup"
    static let recipeImageEntityName = "CDRecipeImage"
    static let mealPlanEntryEntityName = "CDMealPlanEntry"
    static let amountReviewEntityName = "CDAmountReview"
    static let ingredientReviewEntityName = "CDIngredientReview"
    static let vocabularyEntryEntityName = "CDVocabularyEntry"
    static let shoppingEntryEntityName = "CDShoppingEntry"
    static let shoppingPlanEntryEntityName = "CDShoppingPlanEntry"
    static let shoppingDemandEntityName = "CDShoppingDemand"

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

    private static func recipeImageEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = recipeImageEntityName
        entity.managedObjectClassName = NSStringFromClass(CDRecipeImage.self)

        // The one attribute in the whole schema that is not a scalar. Kept out
        // of the row itself the way `@Attribute(.externalStorage)` keeps it out
        // of the SwiftData store: a list that draws thumbnails must not drag
        // megabytes of full-size photo along behind it. Under CloudKit this is
        // also what makes the picture a CKAsset rather than a field.
        let data = attribute("data", .binaryDataAttributeType, optional: true)
        data.allowsExternalBinaryDataStorage = true

        entity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("recipeID", .UUIDAttributeType),
            attribute("sortOrder", .integer64AttributeType, default: 0),
            attribute("createdAt", .dateAttributeType),
            data,
            // Small enough to live in the row and be read for every list cell.
            attribute("thumbnail", .binaryDataAttributeType, optional: true),
        ]
        entity.indexes = [
            index(named: "byRecipeID", on: entity, properties: ["recipeID"]),
            index(named: "byID", on: entity, properties: ["id"]),
        ]
        return entity
    }

    private static func mealPlanEntryEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = mealPlanEntryEntityName
        entity.managedObjectClassName = NSStringFromClass(CDMealPlanEntry.self)
        entity.properties = [
            attribute("id", .UUIDAttributeType),
            // Absent for a pool entry, which is the whole distinction between
            // a meal that sits on a day and one that is merely intended.
            attribute("day", .dateAttributeType, optional: true),
            attribute("slotRaw", .stringAttributeType, default: MealSlot.dinner.rawValue),
            attribute("recipeID", .UUIDAttributeType),
            attribute("servings", .integer64AttributeType, optional: true),
            attribute("sortOrder", .integer64AttributeType, default: 0),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("deletedAt", .dateAttributeType, optional: true),
        ]
        entity.indexes = [
            index(named: "byDay", on: entity, properties: ["day"]),
            index(named: "byID", on: entity, properties: ["id"]),
        ]
        return entity
    }

    /// The two review marks, which are the same row twice.
    ///
    /// Two entities rather than one with a "kind" column, because they answer
    /// different questions and a recipe may have settled one and not the
    /// other — but they share a class and a shape, so they are described once.
    private static func reviewMarkEntity(named name: String) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(CDReviewMark.self)
        entity.properties = [
            attribute("recipeID", .UUIDAttributeType),
            attribute("reviewedContentHash", .stringAttributeType, default: ""),
            attribute("updatedAt", .dateAttributeType),
        ]
        entity.indexes = [index(named: "byRecipeID", on: entity, properties: ["recipeID"])]
        return entity
    }

    private static func vocabularyEntryEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = vocabularyEntryEntityName
        entity.managedObjectClassName = NSStringFromClass(CDVocabularyEntry.self)
        entity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("key", .stringAttributeType, default: ""),
            attribute("name", .stringAttributeType, default: ""),
            attribute("aliasesJSON", .stringAttributeType, default: "[]"),
            attribute("categoryRaw", .stringAttributeType, optional: true),
            // The variety relation, as an id rather than a Core Data
            // relationship — one level deep, and a name changes while an
            // identity does not.
            attribute("parentID", .UUIDAttributeType, optional: true),
            attribute("isOwnIngredient", .booleanAttributeType, default: false),
            attribute("isPantry", .booleanAttributeType, default: false),
            attribute("needsBasisReview", .booleanAttributeType, default: false),
            // The two blobs the shape forces: bases per state and unit
            // weights are dictionaries, read and written whole with the entry.
            attribute("basisData", .binaryDataAttributeType, optional: true),
            attribute("unitWeightData", .binaryDataAttributeType, optional: true),
            attribute("preferredStore", .stringAttributeType, optional: true),
            attribute("shoppingNote", .stringAttributeType, optional: true),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
        ]
        entity.indexes = [
            index(named: "byKey", on: entity, properties: ["key"]),
            index(named: "byParentID", on: entity, properties: ["parentID"]),
        ]
        return entity
    }

    private static func shoppingEntryEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = shoppingEntryEntityName
        entity.managedObjectClassName = NSStringFromClass(CDShoppingEntry.self)
        entity.properties = [
            attribute("itemID", .UUIDAttributeType),
            attribute("key", .stringAttributeType, default: ""),
            attribute("name", .stringAttributeType, default: ""),
            attribute("categoryRaw", .stringAttributeType, optional: true),
            attribute("manualQuantityData", .binaryDataAttributeType, optional: true),
            attribute("isChecked", .booleanAttributeType, default: false),
            attribute("isLateAddition", .booleanAttributeType, default: false),
            // Set when "Erledigte entfernen" swept it off the list; the row
            // stays as the list's memory instead of being deleted.
            attribute("clearedAt", .dateAttributeType, optional: true),
            attribute("sortOrder", .integer64AttributeType, default: 0),
            attribute("addedAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
        ]
        entity.indexes = [index(named: "byKey", on: entity, properties: ["key"])]
        return entity
    }

    private static func shoppingPlanEntryEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = shoppingPlanEntryEntityName
        entity.managedObjectClassName = NSStringFromClass(CDShoppingPlanEntry.self)
        entity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("recipeID", .UUIDAttributeType, optional: true),
            attribute("title", .stringAttributeType, default: ""),
            attribute("servingsCaptured", .integer64AttributeType, default: 1),
            attribute("servingsCurrent", .integer64AttributeType, default: 1),
            attribute("sortOrder", .integer64AttributeType, default: 0),
            attribute("addedAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
        ]
        entity.indexes = [index(named: "byID", on: entity, properties: ["id"])]
        return entity
    }

    private static func shoppingDemandEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = shoppingDemandEntityName
        entity.managedObjectClassName = NSStringFromClass(CDShoppingDemand.self)
        entity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("itemID", .UUIDAttributeType, optional: true),
            // `nil` means frozen — a lapsed remainder that no longer follows
            // any stepper.
            attribute("planEntryID", .UUIDAttributeType, optional: true),
            attribute("lineID", .UUIDAttributeType, optional: true),
            attribute("originTitle", .stringAttributeType, default: ""),
            attribute("writtenName", .stringAttributeType, default: ""),
            attribute("quantityData", .binaryDataAttributeType, optional: true),
            attribute("stateRaw", .stringAttributeType, default: IngredientState.unspecified.rawValue),
            attribute("scales", .booleanAttributeType, default: true),
            attribute("isLate", .booleanAttributeType, default: false),
            attribute("isScaleDiff", .booleanAttributeType, default: false),
            // Named for the storage rather than the reading: the class
            // exposes it as an `Int?`, and a managed property has to carry
            // the attribute's own name.
            attribute("checkedAtServingsValue", .integer64AttributeType, optional: true),
            attribute("lapsedQuantityData", .binaryDataAttributeType, optional: true),
            attribute("isLapsed", .booleanAttributeType, default: false),
            attribute("sortOrder", .integer64AttributeType, default: 0),
            attribute("addedAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
        ]
        entity.indexes = [
            index(named: "byItemID", on: entity, properties: ["itemID"]),
            index(named: "byPlanEntryID", on: entity, properties: ["planEntryID"]),
        ]
        return entity
    }

    /// The row every other row belongs to.
    ///
    /// It exists for one reason: a shared CloudKit zone is entered through an
    /// object graph. `share(_:to:)` carries whatever hangs off the object it
    /// is given, so one household at the root means one call shares the whole
    /// library — and everything written afterwards joins the zone by being
    /// attached to it, rather than by every insert remembering to say so.
    ///
    /// It also answers a question `VISION.md` already asked: which household
    /// a row belongs to has to be on the row, and this is that, as a relation
    /// rather than a loose id. The switch between several households reads it
    /// as a filter.
    private static func householdEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = householdEntityName
        entity.managedObjectClassName = NSStringFromClass(CDHousehold.self)
        entity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("name", .stringAttributeType, default: ""),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
        ]
        entity.indexes = [index(named: "byID", on: entity, properties: ["id"])]
        return entity
    }

    /// Gives every member entity a `household` relation and the household the
    /// inverse — which CloudKit requires: a relationship without one cannot
    /// be mirrored.
    ///
    /// Deleting a household nullifies rather than cascades. Cascade is the
    /// truer reading of "this household is gone", but a bug on that path
    /// would take the whole library with it, while a row left without a
    /// household is visible and repairable — the same bargain a variant makes
    /// when its group row disappears.
    private static func link(_ members: [NSEntityDescription], to household: NSEntityDescription) {
        var inverses: [NSPropertyDescription] = []

        for member in members {
            let toHousehold = NSRelationshipDescription()
            toHousehold.name = "household"
            toHousehold.destinationEntity = household
            toHousehold.minCount = 0
            toHousehold.maxCount = 1
            toHousehold.isOptional = true
            toHousehold.deleteRule = .nullifyDeleteRule

            let toMembers = NSRelationshipDescription()
            // Named after the entity so the household can carry ten of them
            // without collision: "cdRecipes", "cdMealPlanEntries", …
            toMembers.name = memberRelationName(for: member)
            toMembers.destinationEntity = member
            toMembers.minCount = 0
            toMembers.maxCount = 0
            toMembers.isOptional = true
            toMembers.deleteRule = .nullifyDeleteRule

            toHousehold.inverseRelationship = toMembers
            toMembers.inverseRelationship = toHousehold

            member.properties.append(toHousehold)
            inverses.append(toMembers)
        }

        household.properties.append(contentsOf: inverses)
    }

    private static func memberRelationName(for entity: NSEntityDescription) -> String {
        let name = entity.name ?? "members"
        return name.prefix(1).lowercased() + name.dropFirst() + "s"
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
