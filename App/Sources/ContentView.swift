import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No groups yet",
                systemImage: "person.3",
                description: Text("Create a group to start splitting expenses.")
            )
            .navigationTitle("Ledgerline")
        }
    }
}

#Preview {
    ContentView()
}
