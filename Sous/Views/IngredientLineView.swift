import SousKit
import SwiftUI

/// One ingredient line with its three parts told apart: the amount carries the
/// accent because that is what the cook is looking for, the name reads plainly,
/// and the comment steps back.
///
/// The name goes through the markdown parser so that a linked recipe — "1
/// Portion [Naan](sous://recipe/…)" — is a link right there in the list,
/// where the cook is reading, rather than only in a section further down.
struct IngredientLineView: View {
    let ingredient: RecipeIngredient
    var formatter = QuantityFormatter(locale: .sous)
    /// A guessed line, not a stated one — the cook-mode chip that only
    /// matched by name. The amount then steps out of the accent: the tint
    /// is the color of resolved facts, and a name-match heuristic showing
    /// the whole pot must not wear it.
    var provisional = false

    var body: some View {
        // Interpolated rather than added together: `Text + Text` is
        // deprecated as of the 26 SDKs, and interpolation keeps each part's
        // own styling the way the sum did.
        Text("\(amountText)\(amount.isEmpty ? "" : " ")\(name)\(commentText)\(outsideFormText)")
    }

    /// A line outside the fixed form shows its words as written and says
    /// that it waits for the optimization — it scales, and nothing else
    /// about it is read.
    private var outsideFormText: Text {
        guard ingredient.isOutsideForm else { return Text("") }
        return Text("  \(Image(systemName: "sparkles")) neu optimieren")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    /// The amount carries the accent, so it is its own styled run.
    private var amountText: Text {
        provisional
            ? Text(amount).foregroundStyle(.secondary).fontWeight(.medium)
            : Text(amount).foregroundStyle(.tint).fontWeight(.medium)
    }

    private var commentText: Text {
        Text(comment)
            .foregroundStyle(.secondary)
    }

    private var amount: String {
        // The size word is part of the measure, so it wears the measure's
        // accent: "1 kleine" tinted, "Zimtstange" plain.
        ingredient.quantity.map { formatter.string(for: $0, size: ingredient.size) } ?? ""
    }

    private var name: AttributedString {
        AttributedString(inlineMarkdown: ingredient.name)
    }

    private var comment: AttributedString {
        guard let preparation = ingredient.preparation, !preparation.isEmpty else {
            return AttributedString("")
        }
        return AttributedString(" (\(preparation))")
    }
}

// Here rather than in a file of their own because the share extension
// compiles this file too, and its editor reads ingredient names the same way.
extension AttributedString {
    /// Inline markdown — a bold phase name, a linked recipe — falling back to
    /// the raw text if it does not parse, because a half-typed emphasis
    /// marker should not blank out a line.
    init(inlineMarkdown text: String) {
        self = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// A step's resolved segments, concatenated into one string: the words
    /// as inline markdown, a resolved amount in the accent color — the way
    /// ``IngredientLineView`` sets the amount apart in the ingredient list.
    /// One rendering for every place a step is read, so the detail page,
    /// cook mode, the import preview and the references sheet cannot drift.
    init(stepSegments segments: [StepAmountSegment]) {
        self.init()
        for segment in segments {
            switch segment {
            case .text(let string):
                self += AttributedString(inlineMarkdown: string)
            case .amount(let string):
                var run = AttributedString(string)
                run.foregroundColor = .sousAccent
                self += run
            }
        }
    }
}
