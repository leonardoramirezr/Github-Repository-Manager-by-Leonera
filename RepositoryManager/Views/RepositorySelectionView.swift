import SwiftUI

/// Searchable multi-selection list of the account's repositories.
struct RepositorySelectionView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: [String]

    @State private var query = ""

    var body: some View {
        List {
            if let error = state.repositoriesError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let manualEntry {
                Section {
                    Button {
                        toggle(manualEntry)
                    } label: {
                        Label("Añadir «\(manualEntry)»", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("El repositorio no está en la lista, pero puedes añadirlo si el token tiene acceso.")
                }
            }

            if !extraSelected.isEmpty {
                Section("Añadidos manualmente") {
                    ForEach(extraSelected, id: \.self) { name in
                        row(name, isPrivate: nil)
                    }
                }
            }

            Section {
                ForEach(filtered) { repository in
                    row(repository.fullName, isPrivate: repository.isPrivate)
                }
            } header: {
                if !state.repositories.isEmpty {
                    Text(query.isEmpty ? "Repositorios (\(state.repositories.count))" : "Resultados (\(filtered.count))")
                }
            } footer: {
                if !state.settings.account.isEmpty {
                    Text("Solo se muestran los repositorios de \(state.settings.account). Puedes cambiarlo en Ajustes.")
                }
            }
        }
        .overlay {
            if state.isLoadingRepositories && state.repositories.isEmpty {
                ProgressView("Cargando repositorios…")
            } else if filtered.isEmpty && manualEntry == nil && extraSelected.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView(
                        "Sin repositorios",
                        systemImage: "book.closed",
                        description: Text("Desliza hacia abajo para recargar o escribe propietario/repositorio en el buscador.")
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar o propietario/repositorio")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .refreshable {
            await state.loadRepositories()
        }
        .navigationTitle(selection.isEmpty ? "Repositorios" : "\(selection.count) seleccionados")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        for repository in filtered where !isSelected(repository.fullName) {
                            selection.append(repository.fullName)
                        }
                    } label: {
                        Label(query.isEmpty ? "Seleccionar todos" : "Seleccionar resultados", systemImage: "checkmark.circle")
                    }
                    .disabled(filtered.isEmpty)
                    Button(role: .destructive) {
                        selection.removeAll()
                    } label: {
                        Label("Quitar selección", systemImage: "xmark.circle")
                    }
                    .disabled(selection.isEmpty)
                } label: {
                    Label("Selección", systemImage: "checklist")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func row(_ fullName: String, isPrivate: Bool?) -> some View {
        Button {
            toggle(fullName)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected(fullName) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected(fullName) ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
                    Text(parts.last ?? fullName)
                        .foregroundStyle(.primary)
                    if parts.count == 2 {
                        Text(parts[0])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer()
                if let isPrivate {
                    Image(systemName: isPrivate ? "lock.fill" : "globe")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(isPrivate ? "Privado" : "Público")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected(fullName) ? .isSelected : [])
    }

    private var filtered: [Repository] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return state.repositories }
        return state.repositories.filter { $0.fullName.localizedCaseInsensitiveContains(text) }
    }

    /// Selected repositories that are not in the loaded list (typed manually).
    private var extraSelected: [String] {
        selection.filter { name in
            !state.repositories.contains { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Lets the user type "owner/repo" for repositories missing from the list.
    private var manualEntry: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: "/")
        guard parts.count == 2, !text.contains(" "), !isSelected(text) else { return nil }
        let exists = state.repositories.contains { $0.fullName.caseInsensitiveCompare(text) == .orderedSame }
        return exists ? nil : text
    }

    private func isSelected(_ fullName: String) -> Bool {
        selection.contains { $0.caseInsensitiveCompare(fullName) == .orderedSame }
    }

    private func toggle(_ fullName: String) {
        if isSelected(fullName) {
            selection.removeAll { $0.caseInsensitiveCompare(fullName) == .orderedSame }
        } else {
            selection.append(fullName)
            if fullName == manualEntry { query = "" }
        }
    }
}
