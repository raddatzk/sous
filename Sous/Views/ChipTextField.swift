import SwiftUI

/// A field whose contents are values rather than a line of text: each entry
/// becomes a chip that can be removed on its own.
///
/// The alternative is a comma-separated line, which is what this replaces.
/// A line puts the work of parsing on the reader as much as on the code —
/// "Schnell,,Salate " looks fine while typing and is only quietly cleaned up
/// on saving, and nothing tells the writer that they have just entered
/// "Salate" a second time. Chips make both visible while there is still
/// something to be done about it.
///
/// SwiftUI has no such control: `TextField` carries no tokens, and the one
/// native token API — `searchable(text:tokens:)` — belongs to the navigation
/// search field and cannot be put in a form. So it is built here, out of
/// ``FlowLayout`` and an ordinary field sitting after the chips.
struct ChipTextField: View {
    @Binding var values: [String]
    var placeholder: String
    /// What to offer under the field for what is currently typed. Given the
    /// partial entry, since the caller knows where suggestions come from.
    var suggestions: (String) -> [String] = { _ in [] }

    @State private var text = ""
    @FocusState private var isTyping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout {
                ForEach(values, id: \.self) { value in
                    chip(value)
                }
                field
            }
            .sousFieldBox()

            suggestionStrip
        }
    }

    @ViewBuilder
    private var field: some View {
        TextField(values.isEmpty ? placeholder : "", text: $text)
            .textFieldStyle(.plain)
            .frame(minWidth: 120)
            .focused($isTyping)
            #if os(iOS)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            #endif
            // A comma is how anyone who has met such a field before ends an
            // entry, so it is taken as one rather than typed into a chip.
            .onChange(of: text) { commitCompleteEntries() }
            .onSubmit { commit(text) }
            // Backspace in an empty field takes the last chip back, which is
            // the one thing a chip field is expected to do and the one thing
            // iOS gives no way to notice.
            #if os(macOS)
            .onKeyPress(.delete) {
                guard text.isEmpty, !values.isEmpty else { return .ignored }
                values.removeLast()
                return .handled
            }
            #endif
    }

    @ViewBuilder
    private func chip(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.callout)
            Button("Entfernen", systemImage: "xmark") {
                values.removeAll { $0 == value }
            }
            .labelStyle(.iconOnly)
            .font(.caption2)
            .buttonStyle(.plain)
        }
        .sousChip()
    }

    @ViewBuilder
    private var suggestionStrip: some View {
        let matches = suggestions(text)
        if isTyping, !matches.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(matches, id: \.self) { match in
                        Button {
                            commit(match)
                        } label: {
                            Text(match)
                                .font(.callout)
                                .sousSuggestionChip()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Turns everything before a comma into chips, leaving the rest being
    /// typed. Handles a pasted "Salate, Schnell" as well as a typed one.
    private func commitCompleteEntries() {
        guard text.contains(",") else { return }
        var entries = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let remainder = entries.removeLast()
        for entry in entries { add(entry) }
        text = remainder
    }

    private func commit(_ entry: String) {
        add(entry)
        text = ""
    }

    /// Adds an entry unless it is empty or already there. Case is ignored on
    /// the comparison but kept on what is stored: "Salate" and "salate" are
    /// the same category, and the first spelling is the one that wins.
    private func add(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !values.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        values.append(trimmed)
    }
}
