import SousKit
import SwiftUI

/// What the planned week needs from the shop.
struct ShoppingListView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Einkaufsliste",
                systemImage: "cart",
                description: Text("Wird aus dem Essensplan zusammengestellt. Kommt als Nächstes.")
            )
            .navigationTitle("Einkaufsliste")
        }
    }
}
