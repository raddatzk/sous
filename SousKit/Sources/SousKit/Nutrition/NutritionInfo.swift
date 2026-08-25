import Foundation

/// Nutrient values per 100 g, sourced from BLS (Bundeslebensmittelschlüssel).
public struct NutritionInfo: Hashable, Sendable {
    public var kcal: Double
    public var proteinG: Double
    public var fatG: Double
    public var saturatedFatG: Double
    public var carbsG: Double
    public var sugarG: Double
    public var fiberG: Double
    public var sodiumMg: Double
    public var vitaminAMcg: Double
    public var vitaminCMg: Double
    public var vitaminDMcg: Double
    public var vitaminEMg: Double
    public var calciumMg: Double
    public var ironMg: Double
    public var magnesiumMg: Double
    public var potassiumMg: Double

    public static let zero = NutritionInfo(
        kcal: 0, proteinG: 0, fatG: 0, saturatedFatG: 0, carbsG: 0, sugarG: 0, fiberG: 0, sodiumMg: 0,
        vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0, vitaminEMg: 0,
        calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
    )

    public init(
        kcal: Double, proteinG: Double, fatG: Double, saturatedFatG: Double,
        carbsG: Double, sugarG: Double, fiberG: Double, sodiumMg: Double,
        vitaminAMcg: Double, vitaminCMg: Double, vitaminDMcg: Double, vitaminEMg: Double,
        calciumMg: Double, ironMg: Double, magnesiumMg: Double, potassiumMg: Double
    ) {
        self.kcal = kcal
        self.proteinG = proteinG
        self.fatG = fatG
        self.saturatedFatG = saturatedFatG
        self.carbsG = carbsG
        self.sugarG = sugarG
        self.fiberG = fiberG
        self.sodiumMg = sodiumMg
        self.vitaminAMcg = vitaminAMcg
        self.vitaminCMg = vitaminCMg
        self.vitaminDMcg = vitaminDMcg
        self.vitaminEMg = vitaminEMg
        self.calciumMg = calciumMg
        self.ironMg = ironMg
        self.magnesiumMg = magnesiumMg
        self.potassiumMg = potassiumMg
    }

    /// This ingredient's nutrients for `grams` of it, scaling from the
    /// per-100g values this struct always holds.
    public func scaled(byGrams grams: Double) -> NutritionInfo {
        let factor = grams / 100
        return NutritionInfo(
            kcal: kcal * factor, proteinG: proteinG * factor, fatG: fatG * factor,
            saturatedFatG: saturatedFatG * factor, carbsG: carbsG * factor, sugarG: sugarG * factor,
            fiberG: fiberG * factor, sodiumMg: sodiumMg * factor,
            vitaminAMcg: vitaminAMcg * factor, vitaminCMg: vitaminCMg * factor,
            vitaminDMcg: vitaminDMcg * factor, vitaminEMg: vitaminEMg * factor,
            calciumMg: calciumMg * factor, ironMg: ironMg * factor,
            magnesiumMg: magnesiumMg * factor, potassiumMg: potassiumMg * factor
        )
    }

    /// This total multiplied by a plain factor — used to go from a recipe's
    /// full-batch total to its per-portion figure (`factor = 1 / servings`),
    /// as opposed to `scaled(byGrams:)`, which scales from a per-100g value.
    public func scaled(by factor: Double) -> NutritionInfo {
        NutritionInfo(
            kcal: kcal * factor, proteinG: proteinG * factor, fatG: fatG * factor,
            saturatedFatG: saturatedFatG * factor, carbsG: carbsG * factor, sugarG: sugarG * factor,
            fiberG: fiberG * factor, sodiumMg: sodiumMg * factor,
            vitaminAMcg: vitaminAMcg * factor, vitaminCMg: vitaminCMg * factor,
            vitaminDMcg: vitaminDMcg * factor, vitaminEMg: vitaminEMg * factor,
            calciumMg: calciumMg * factor, ironMg: ironMg * factor,
            magnesiumMg: magnesiumMg * factor, potassiumMg: potassiumMg * factor
        )
    }

    public static func + (lhs: NutritionInfo, rhs: NutritionInfo) -> NutritionInfo {
        NutritionInfo(
            kcal: lhs.kcal + rhs.kcal, proteinG: lhs.proteinG + rhs.proteinG, fatG: lhs.fatG + rhs.fatG,
            saturatedFatG: lhs.saturatedFatG + rhs.saturatedFatG, carbsG: lhs.carbsG + rhs.carbsG,
            sugarG: lhs.sugarG + rhs.sugarG, fiberG: lhs.fiberG + rhs.fiberG, sodiumMg: lhs.sodiumMg + rhs.sodiumMg,
            vitaminAMcg: lhs.vitaminAMcg + rhs.vitaminAMcg, vitaminCMg: lhs.vitaminCMg + rhs.vitaminCMg,
            vitaminDMcg: lhs.vitaminDMcg + rhs.vitaminDMcg, vitaminEMg: lhs.vitaminEMg + rhs.vitaminEMg,
            calciumMg: lhs.calciumMg + rhs.calciumMg, ironMg: lhs.ironMg + rhs.ironMg,
            magnesiumMg: lhs.magnesiumMg + rhs.magnesiumMg, potassiumMg: lhs.potassiumMg + rhs.potassiumMg
        )
    }
}

extension NutritionInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case kcal, proteinG, fatG, saturatedFatG, carbsG, sugarG, fiberG, sodiumMg
        case vitaminAMcg, vitaminCMg, vitaminDMcg, vitaminEMg
        case calciumMg, ironMg, magnesiumMg, potassiumMg
    }

    /// Source rows occasionally lack a value for a rarer nutrient; treated as
    /// 0 rather than failing the whole ingredient over one missing field.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) -> Double {
            (try? container.decodeIfPresent(Double.self, forKey: key)) ?? 0
        }
        self.init(
            kcal: value(.kcal), proteinG: value(.proteinG), fatG: value(.fatG),
            saturatedFatG: value(.saturatedFatG), carbsG: value(.carbsG), sugarG: value(.sugarG),
            fiberG: value(.fiberG), sodiumMg: value(.sodiumMg),
            vitaminAMcg: value(.vitaminAMcg), vitaminCMg: value(.vitaminCMg),
            vitaminDMcg: value(.vitaminDMcg), vitaminEMg: value(.vitaminEMg),
            calciumMg: value(.calciumMg), ironMg: value(.ironMg),
            magnesiumMg: value(.magnesiumMg), potassiumMg: value(.potassiumMg)
        )
    }
}
