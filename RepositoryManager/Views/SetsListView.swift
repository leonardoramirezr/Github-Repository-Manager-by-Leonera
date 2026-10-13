import SwiftUI

/// Main screen: the list of secret sets.
struct SetsListView: View {
    @Environment(AppState.self) private var state
    @State private var showSettings = false
    @State private var pendingDeletion: SecretSet?

    var body: some View {
        @Bindable var state = state
        NavigationStack(path: $state.path) {
            List {
                ForEach(state.secretSets) { set in
                    NavigationLink(value: Route.set(set.id)) {
                        SetRow(set: set)
                    }
                    .swipeActions(edge: .trailing) {
                        // Not role: .destructive, which would animate the row away before confirming.
                        Button {
                            pendingDeletion = set
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                        .tint(.red)
                        Button {
                            state.duplicateSet(set.id)
                        } label: {
                            Label("Duplicar", systemImage: "plus.square.on.square")
                        }
                        .tint(.indigo)
                    }
                    .contextMenu {
                        Button {
                            state.duplicateSet(set.id)
                        } label: {
                            Label("Duplicar", systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive) {
                            pendingDeletion = set
                        } label: {
                            Label("Eliminar…", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if state.secretSets.isEmpty {
                    ContentUnavailableView {
                        Label("Sin presets", systemImage: "slider.horizontal.3")
                    } description: {
                        Text("Un preset agrupa secretos y ajustes de repositorio (pull requests y GitHub Pages) y los repositorios a los que se aplican.")
                    } actions: {
                        Button("Crear preset") { state.addSet() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Presets")
            .navigationDestination(for: Route.self) { route in
                if state.secretSets.contains(where: { $0.id == route.setID }) {
                    switch route {
                    case .set(let id):
                        SecretSetDetailView(secretSet: binding(for: id))
                    case .repositories(let id):
                        RepositorySelectionView(selection: binding(for: id).repositories)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Ajustes", systemImage: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        state.addSet()
                    } label: {
                        Label("Nuevo preset", systemImage: "plus")
                    }
                }
            }
        }
        .task {
            if state.repositories.isEmpty {
                await state.loadRepositories()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $state.showUploadSheet) {
            UploadView()
        }
        .confirmationDialog(
            "¿Eliminar «\(pendingDeletion?.displayName ?? "")»?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { set in
            Button("Eliminar preset", role: .destructive) { state.deleteSet(set.id) }
        } message: { _ in
            Text("Se borrará el preset y sus valores guardados en este iPhone. Lo ya aplicado en GitHub no se modifica.")
        }
    }

    /// Binding looked up by id, so removing sets never leaves a dangling index.
    private func binding(for id: SecretSet.ID) -> Binding<SecretSet> {
        Binding(
            get: { state.secretSets.first(where: { $0.id == id }) ?? SecretSet(id: id, name: "") },
            set: { newValue in
                if let index = state.secretSets.firstIndex(where: { $0.id == id }) {
                    state.secretSets[index] = newValue
                }
            }
        )
    }
}

private struct SetRow: View {
    let set: SecretSet

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: set.target.systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(set.problems.isEmpty ? Color.accentColor : Color.orange, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(set.displayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label("\(set.secrets.count)", systemImage: "key.fill")
                    Label(set.repositoriesSummary, systemImage: "book.closed.fill")
                        .lineLimit(1)
                }
                .labelStyle(CompactLabelStyle())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let lastSent = set.lastSentAt {
                    Text("Enviado \(lastSent.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Icon and title close together, for dense metadata rows.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}
