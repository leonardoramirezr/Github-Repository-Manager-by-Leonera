import SwiftUI

@main
struct RepositoryManagerApp: App {
    @State private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                state.saveNow()
            }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.isConfigured {
                TabView {
                    SetsListView()
                        .tabItem { Label("Secretos", systemImage: "key.horizontal") }
                    RepositoriesView()
                        .tabItem { Label("Repositorios", systemImage: "book.closed") }
                }
            } else {
                OnboardingView()
            }
        }
        .onChange(of: state.secretSets) {
            state.scheduleSave()
        }
        .alert("No se pudo acceder al Llavero", isPresented: storageErrorPresented) {
            Button("Aceptar") {}
        } message: {
            Text(state.storageError ?? "")
        }
    }

    private var storageErrorPresented: Binding<Bool> {
        Binding(
            get: { state.storageError != nil },
            set: { if !$0 { state.storageError = nil } }
        )
    }
}
