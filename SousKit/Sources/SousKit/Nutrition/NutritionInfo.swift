import Foundation

/// One of the nutrients `NutritionInfo` carries, named as the data files name
/// it — what lets a value be *absent* rather than zero.
public enum Nutrient: String, CaseIterable, Codable, Hashable, Sendable, Comparable {
    case kcal, proteinG, fatG, saturatedFatG, carbsG, sugarG, fiberG, sodiumMg
    case vitaminAMcg, vitaminCMg, vitaminDMcg, vitaminEMg
    case calciumMg, ironMg, magnesiumMg, potassiumMg

    public var keyPath: WritableKeyPath<NutritionInfo, Double> {
        switch self {
        case .kcal: \.kcal
        case .proteinG: \.proteinG
        case .fatG: \.fatG
        case .saturatedFatG: \.saturatedFatG
        case .carbsG: \.carbsG
        case .sugarG: \.sugarG
        case .fiberG: \.fiberG
        case .sodiumMg: \.sodiumMg
        case .vitaminAMcg: \.vitaminAMcg
        case .vitaminCMg: \.vitaminCMg
        case .vitaminDMcg: \.vitaminDMcg
        case .vitaminEMg: \.vitaminEMg
        case .calciumMg: \.calciumMg
        case .ironMg: \.ironMg
        case .magnesiumMg: \.magnesiumMg
        case .potassiumMg: \.potassiumMg
        }
    }

    /// The word the app uses for it.
    public var label: String {
        switch self {
        case .kcal: "Energie"
        case .proteinG: "Eiweiß"
        case .fatG: "Fett"
        case .saturatedFatG: "Gesättigte Fettsäuren"
        case .carbsG: "Kohlenhydrate"
        case .sugarG: "Zucker"
        case .fiberG: "Ballaststoffe"
        case .sodiumMg: "Natrium"
        case .vitaminAMcg: "Vitamin A"
        case .vitaminCMg: "Vitamin C"
        case .vitaminDMcg: "Vitamin D"
        case .vitaminEMg: "Vitamin E"
        case .calciumMg: "Calcium"
        case .ironMg: "Eisen"
        case .magnesiumMg: "Magnesium"
        case .potassiumMg: "Kalium"
        }
    }

    public static func < (lhs: Nutrient, rhs: Nutrient) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Nutrient values per 100 g, sourced from BLS (Bundeslebensmittelschlüssel).
///
/// A value the source does not state is *absent*, not zero: 656 BLS rows
/// leave a nutrient out, and a label states the macronutrients and rarely
/// more. Its number reads 0, so sums and scores keep working, and `absent`
/// says which numbers are no statement at all. `NutritionCoverage` turns
/// that into a share per nutrient, which the NRF badge and the fibre tag
/// ask for before they say anything.
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
    /// The nutrients the source left out. For a sum: those some part of it
    /// left out — how much of the sum that part is, the coverage says.
    public var absent: Set<Nutrient> = []

    public static let zero = NutritionInfo(
        kcal: 0, proteinG: 0, fatG: 0, saturatedFatG: 0, carbsG: 0, sugarG: 0, fiberG: 0, sodiumMg: 0,
        vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0, vitaminEMg: 0,
        calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
    )

    public init(
        kcal: Double, proteinG: Double, fatG: Double, saturatedFatG: Double,
        carbsG: Double, sugarG: Double, fiberG: Double, sodiumMg: Double,
        vitaminAMcg: Double, vitaminCMg: Double, vitaminDMcg: Double, vitaminEMg: Double,
        calciumMg: Double, ironMg: Double, magnesiumMg: Double, potassiumMg: Double,
        absent: Set<Nutrient> = []
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
        self.absent = absent
    }

    /// Whether the source stated this nutrient at all.
    public func states(_ nutrient: Nutrient) -> Bool { !absent.contains(nutrient) }

    /// The value, or `nil` where the source said nothing.
    public subscript(nutrient: Nutrient) -> Double? {
        absent.contains(nutrient) ? nil : self[keyPath: nutrient.keyPath]
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
            magnesiumMg: magnesiumMg * factor, potassiumMg: potassiumMg * factor,
            absent: absent
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
            magnesiumMg: magnesiumMg * factor, potassiumMg: potassiumMg * factor,
            absent: absent
        )
    }

    /// Field by field; a nutrient either side left out is marked absent in
    /// the sum, whose number is then what the stating side gave.
    public static func + (lhs: NutritionInfo, rhs: NutritionInfo) -> NutritionInfo {
        NutritionInfo(
            kcal: lhs.kcal + rhs.kcal, proteinG: lhs.proteinG + rhs.proteinG, fatG: lhs.fatG + rhs.fatG,
            saturatedFatG: lhs.saturatedFatG + rhs.saturatedFatG, carbsG: lhs.carbsG + rhs.carbsG,
            sugarG: lhs.sugarG + rhs.sugarG, fiberG: lhs.fiberG + rhs.fiberG, sodiumMg: lhs.sodiumMg + rhs.sodiumMg,
            vitaminAMcg: lhs.vitaminAMcg + rhs.vitaminAMcg, vitaminCMg: lhs.vitaminCMg + rhs.vitaminCMg,
            vitaminDMcg: lhs.vitaminDMcg + rhs.vitaminDMcg, vitaminEMg: lhs.vitaminEMg + rhs.vitaminEMg,
            calciumMg: lhs.calciumMg + rhs.calciumMg, ironMg: lhs.ironMg + rhs.ironMg,
            magnesiumMg: lhs.magnesiumMg + rhs.magnesiumMg, potassiumMg: lhs.potassiumMg + rhs.potassiumMg,
            absent: lhs.absent.union(rhs.absent)
        )
    }
}

extension NutritionInfo: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }

        static let absent = Key(stringValue: "absent")
    }

    /// A key the source leaves out is absent — the BLS and label rows are
    /// written that way. A stored figure lists its absent nutrients under
    /// `absent`, because a sum keeps the number the stating parts gave.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var info = NutritionInfo.zero
        for nutrient in Nutrient.allCases {
            if let value = try? container.decodeIfPresent(Double.self, forKey: Key(stringValue: nutrient.rawValue)) {
                info[keyPath: nutrient.keyPath] = value
            } else {
                info.absent.insert(nutrient)
            }
        }
        if let listed = try? container.decodeIfPresent([String].self, forKey: .absent) {
            info.absent.formUnion(listed.compactMap(Nutrient.init(rawValue:)))
        }
        self = info
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for nutrient in Nutrient.allCases {
            try container.encode(self[keyPath: nutrient.keyPath], forKey: Key(stringValue: nutrient.rawValue))
        }
        if !absent.isEmpty {
            try container.encode(absent.sorted().map(\.rawValue), forKey: .absent)
        }
    }
}

extension NutritionInfo {
    /// Milligrams of sodium per gram of salt: a label prints salt, the data
    /// stores sodium.
    public static let sodiumMgPerSaltGram = 400.0

    /// Values as a label states them, per 100 g: what it leaves out is
    /// absent — a blank field, and every micronutrient, which a label rarely
    /// declares. Nothing is extrapolated (INGREDIENTS-DATA §3 I).
    public static func label(
        kcal: Double?, proteinG: Double?, fatG: Double?, saturatedFatG: Double?,
        carbsG: Double?, sugarG: Double?, fiberG: Double?, saltG: Double?
    ) -> NutritionInfo {
        let stated: [(Nutrient, Double?)] = [
            (.kcal, kcal), (.proteinG, proteinG), (.fatG, fatG), (.saturatedFatG, saturatedFatG),
            (.carbsG, carbsG), (.sugarG, sugarG), (.fiberG, fiberG),
            (.sodiumMg, saltG.map { $0 * sodiumMgPerSaltGram }),
        ]
        var info = NutritionInfo.zero
        info.absent = Set(Nutrient.allCases)
        for (nutrient, value) in stated {
            guard let value else { continue }
            info[keyPath: nutrient.keyPath] = value
            info.absent.remove(nutrient)
        }
        return info
    }
}
