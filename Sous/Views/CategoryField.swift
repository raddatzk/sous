import SousKit
import SwiftUI

/// A recipe's categories, as chips in a field.
///
/// Categories are free text, but they are only worth anything when the same
/// dish lands under the same word every time — so the field is built around
/// the ones that already exist: typing offers them, tapping one takes it, and
/// a chip carries the colour that category has everywhere else in the app.
/// Typing a name nobody has used yet still works; it is one more tap, which
/// is the right way round for something that quietly creates a category.
///
/// A chip goes away either by being tapped and then backspaced — the tap
/// marks it, so it is clear what is about to go — or by a backspace with the
/// cursor sitting right behind the chips, which is what every token field
/// since Mail has done. See ``fieldText`` for how a keystroke nobody reports
/// is noticed at all.
struct CategoryField: View {
    @Binding var categories: [String]
    /// What is in the field but is not a chip yet.
    ///
    /// Held by the editor rather than here, so that saving with a half-typed
    /// category in the field can still keep it: a word typed and then
    /// confirmed with "Sichern" is meant, and dropping it because it never
    /// got its return key would be a small theft.
    @Binding var typed: String
    /// Every category the library already uses, for suggesting and for
    /// settling spelling.
    let known: [String]
    @FocusState.Binding var focus: EditorField?

    /// The chip a tap has marked, waiting for the backspace that removes it.
    /// Case is kept as the chip has it, and compared without.
    @State private var marked: String?

    /// An invisible character the field's text always begins with.
    ///
    /// Neither SwiftUI's `TextField` nor anything under it reports a
    /// backspace pressed in an empty field — there is no edit to report, so
    /// the one keystroke this field needs most arrives nowhere. So the field
    /// is never empty: it holds a zero-width space that draws nothing and
    /// takes no room, and a backspace at the front of the field deletes
    /// *that* instead. The edit that is reported is the anchor going
    /// missing, which is the signal.
    private static let anchor = "\u{200B}"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(categories, id: \.self) { category in
                    chip(category)
                }
                entryField
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sousFieldBox()
            // The box is bigger than the field inside it, and the empty part
            // of it is where a finger naturally goes to add one more.
            .contentShape(.rect)
            .onTapGesture {
                marked = nil
                focus = .categories
            }
            offers
        }
        .animation(.smooth(duration: 0.2), value: categories)
        .onChange(of: focus) { _, moved in
            guard moved != .categories else { return }
            // Leaving the field finishes the word standing in it — a name
            // typed and then left behind is meant just as much as one
            // ended with the return key. And a marked chip is waiting for a
            // keyboard that is no longer there, so the mark goes with it.
            if typed.isEmpty {
                marked = nil
            } else {
                commit(typed)
            }
        }
    }

    /// One category the recipe carries.
    ///
    /// Marked, it swaps ground and ink: a ring or a heavier border would
    /// have to compete with a capsule that is already tinted, and the point
    /// of marking is that there is no doubt which chip the next backspace
    /// takes.
    private func chip(_ name: String) -> some View {
        let colour = Color.sousCategory(name)
        let isMarked = marked?.lowercased() == name.lowercased()
        return Button {
            marked = isMarked ? nil : name
            // Marking without a keyboard would be a dead end: the backspace
            // that finishes the job is on it.
            focus = .categories
        } label: {
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isMarked ? colour : colour.opacity(SousStyle.chipTint), in: .capsule)
                .foregroundStyle(isMarked ? Color.sousBackground : colour)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMarked ? "\(name), markiert" : name)
        .accessibilityHint("Markiert die Kategorie; Rückschritt entfernt sie.")
        // The tap-then-backspace pair is a keyboard gesture, and VoiceOver
        // has no keyboard to reach for.
        .accessibilityAction(named: "Entfernen") { remove(name) }
    }

    private var entryField: some View {
        TextField("", text: fieldText)
            .textFieldStyle(.plain)
            // Category names are the cook's own words — a food dictionary is
            // exactly what should not have a say in them.
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
            .focused($focus, equals: .categories)
            .onSubmit { commit(typed) }
            // The prompt below is drawn by hand, so the field would
            // otherwise be an unnamed one to anyone listening.
            .accessibilityLabel("Kategorie")
            // Wide enough to be worth aiming at while empty, capped so one
            // long word does not push the chips beside it off the line.
            .frame(minWidth: 150, maxWidth: 260)
            .overlay(alignment: .leading) {
                // The field's own prompt would never show: its text is never
                // empty, it always holds the anchor.
                if typed.isEmpty {
                    Text("Kategorie")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
    }

    /// The field's text: the anchor, then whatever is being typed.
    ///
    /// Written as a binding rather than state of its own so there is one
    /// answer to what is in the field, and so the anchor never leaks out to
    /// anyone who might save it as part of a category name.
    private var fieldText: Binding<String> {
        Binding(
            get: { Self.anchor + typed },
            set: { newValue in
                guard newValue.hasPrefix(Self.anchor) else {
                    // The anchor is gone. If nothing else changed with it,
                    // it was deleted on its own — a backspace at the very
                    // front of the field, reaching for the chip the cursor
                    // sits behind. Anything else is a replacement of the
                    // whole field (select all, then type), which is
                    // ordinary typing and no business of the chips'.
                    if newValue == typed {
                        deleteMarkedOrLast()
                    } else {
                        typed = newValue
                        marked = nil
                    }
                    return
                }
                let entered = String(newValue.dropFirst(Self.anchor.count))
                marked = nil
                // A comma still ends a category, for anyone with the old
                // field's habit and for a list pasted in from somewhere else.
                if entered.contains(where: { $0 == "," || $0.isNewline }) {
                    commit(entered)
                } else {
                    typed = entered
                }
            }
        )
    }

    /// What the typing could become, under the field.
    @ViewBuilder
    private var offers: some View {
        let suggestions = CategoryCompletion.suggestions(
            for: typed,
            categories: known,
            excluding: Set(categories)
        )
        if !suggestions.isEmpty || isNewName {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(suggestions, id: \.self) { name in
                    offer(name)
                }
                if isNewName {
                    // Last, and marked as the new thing it is: everything
                    // above it files the recipe with recipes that already
                    // exist, and this one does not.
                    offer(typed.trimmingCharacters(in: .whitespaces), isNew: true)
                }
            }
            .transition(.opacity)
        }
    }

    /// A category being offered rather than held: neutral ground, since
    /// taking it is what tints it — but already in its own colour, so the
    /// chip it is about to become is recognizable before the tap.
    private func offer(_ name: String, isNew: Bool = false) -> some View {
        Button {
            commit(name)
        } label: {
            HStack(spacing: 4) {
                if isNew {
                    Image(systemName: "plus")
                }
                Text(name)
            }
            .font(.subheadline)
            .lineLimit(1)
            .fixedSize()
            .sousSuggestionChip()
            .foregroundStyle(Color.sousCategory(name))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isNew ? "Neue Kategorie \(name) hinzufügen" : "\(name) hinzufügen")
    }

    /// Whether what is typed would start a category rather than join one.
    private var isNewName: Bool {
        let name = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return false }
        return !known.contains { $0.lowercased() == name }
            && !categories.contains { $0.lowercased() == name }
    }

    private func commit(_ name: String) {
        categories = CategoryCompletion.adding(name, to: categories, known: known)
        typed = ""
        marked = nil
    }

    private func remove(_ name: String) {
        categories.removeAll { $0.lowercased() == name.lowercased() }
        marked = nil
    }

    /// The chip a backspace takes: the marked one if a tap named it, and
    /// otherwise the one the cursor is sitting behind.
    private func deleteMarkedOrLast() {
        if let marked {
            remove(marked)
        } else if let last = categories.last {
            remove(last)
        }
    }
}
