import SwiftUI

public struct ChipTextField: View {
    @Binding var values: [String]
    let placeholder: String
    let suggestions: (String) -> [String]
    
    @State private var input: String = ""
    @FocusState private var isFocused: Bool
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout {
                ForEach(values, id: \.self) { value in
                    chipView(for: value)
                }
                TextField(
                    (values.isEmpty && input.isEmpty) ? placeholder : "",
                    text: $input
                )
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onChange(of: input) { newValue in
                    if newValue.contains(",") {
                        // Split by comma
                        let parts = newValue.split(separator: ",", omittingEmptySubsequences: false)
                        if let first = parts.first {
                            addValue(String(first).trimmingCharacters(in: .whitespaces))
                        }
                        // Keep remainder after the last comma (if any)
                        if let last = parts.last, parts.count > 1 {
                            var remainder = String(last)
                            // If there were multiple commas, that might cause empty parts
                            // Keep only the remainder after last comma trimmed leading whitespace
                            remainder = remainder.trimmingCharacters(in: .whitespaces)
                            input = remainder
                        } else {
                            input = ""
                        }
                    }
                }
                .onSubmit {
                    commitToken()
                }
            }
            .sousFieldBox()
            
            if isFocused, !input.isEmpty {
                let sug = suggestions(input)
                if !sug.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(sug, id: \.self) { suggestion in
                                Button {
                                    addValue(suggestion)
                                    input = ""
                                    isFocused = true
                                } label: {
                                    Text(suggestion)
                                        .sousSuggestionChip()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }
    
    private func commitToken() {
        let token = input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        guard !token.isEmpty else { return }
        addValue(token)
        input = ""
    }
    
    private func addValue(_ text: String) {
        if !values.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
            values.append(text)
        }
    }
    
    @ViewBuilder
    private func chipView(for value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
            Button {
                values.removeAll(where: { $0 == value })
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
        }
        .sousChip()
    }
}
