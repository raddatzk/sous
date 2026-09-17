import SwiftUI

/// What an empty list says while its content is still on the way from
/// iCloud — in place of the invitation to start one, which would be the
/// opposite of the truth. See `CloudKitInitialImport`.
struct InitialImportPlaceholder: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                ProgressView()
            }
        } description: {
            Text(description)
        }
    }
}

/// The quieter version for a list that already shows part of what is coming:
/// one row at its end, gone once the import is.
struct InitialImportRow: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
