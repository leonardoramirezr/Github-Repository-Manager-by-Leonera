import SwiftUI

/// "Repositorios" tab: searchable list of the account's repositories, each opening its settings.
struct RepositoriesView: View {
    @Environment(AppState.self) private var state
    @State private var showSettings = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
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
                        NavigationLink(value: manualEntry) {
                            Label("Abrir «\(manualEntry)»", systemImage: "arrow.right.circle.fill")
                        }
                    } footer: {
                        Text("El repositorio no está en la lista, pero puedes abrirlo si el token tiene acceso.")
                    }
                }

                Section {
                    ForEach(filtered) { repository in
                        NavigationLink(value: repository.fullName) {
                            RepositoryRow(repository: repository)
                        }
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
                } else if filtered.isEmpty && manualEntry == nil {
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
            .searchable(text: $query, prompt: "Buscar o propietario/repositorio")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .refreshable {
                await state.loadRepositories()
            }
            .navigationTitle("Repositorios")
            .navigationDestination(for: String.self) { repository in
                RepositorySettingsView(repository: repository)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Ajustes", systemImage: "person.crop.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var filtered: [Repository] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return state.repositories }
        return state.repositories.filter { $0.fullName.localizedCaseInsensitiveContains(text) }
    }

    /// Lets the user type "owner/repo" for repositories missing from the list.
    private var manualEntry: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.split(separator: "/").count == 2, !text.contains(" ") else { return nil }
        let exists = state.repositories.contains { $0.fullName.caseInsensitiveCompare(text) == .orderedSame }
        return exists ? nil : text
    }
}

private struct RepositoryRow: View {
    let repository: Repository

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                let parts = repository.fullName.split(separator: "/", maxSplits: 1).map(String.init)
                Text(parts.last ?? repository.fullName)
                if parts.count == 2 {
                    Text(parts[0])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer()
            Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(repository.isPrivate ? "Privado" : "Público")
        }
    }
}

/// Pull request and GitHub Pages settings of one repository.
struct RepositorySettingsView: View {
    @Environment(AppState.self) private var state
    let repository: String

    @State private var isLoading = false
    @State private var loadError: String?
    @State private var details: RepositoryDetails?
    /// Values as loaded from GitHub, to send only what changed.
    @State private var original = RepositorySettings()
    @State private var edited = RepositorySettings()
    /// nil while not loaded or when Pages is not enabled.
    @State private var originalPages: PagesSettings?
    @State private var pages: PagesSettings?
    @State private var pagesError: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saved = false

    var body: some View {
        Form {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Reintentar") { Task { await load() } }
                }
            } else if let details {
                if details.permissions?.admin == false {
                    Section {
                        Label("No eres administrador de este repositorio: GitHub rechazará los cambios.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                pullRequestsSection(details)
                pagesSection(details)
                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .overlay {
            if isLoading && details == nil {
                ProgressView("Cargando ajustes…")
            }
        }
        .navigationTitle(String(repository.split(separator: "/").last ?? Substring(repository)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Guardar") { Task { await save() } }
                        .bold()
                        .disabled(!canSave)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sensoryFeedback(.success, trigger: saved) { _, new in new }
    }

    // MARK: - Sections

    private func pullRequestsSection(_ details: RepositoryDetails) -> some View {
        Section {
            if edited.pullRequestCreationPolicy != nil {
                Picker(selection: $edited.pullRequestCreationPolicy) {
                    ForEach(PullRequestCreationPolicy.allCases) { policy in
                        Text(policy.title).tag(Optional(policy))
                    }
                } label: {
                    Label("Pueden crear pull requests", systemImage: "person.2")
                }
            }
            Group {
                Toggle(isOn: $edited.allowMergeCommit) {
                    Label("Permitir merge commits", systemImage: "arrow.triangle.merge")
                }
                Toggle(isOn: $edited.allowSquashMerge) {
                    Label("Permitir squash merging", systemImage: "square.stack.3d.down.right")
                }
                Toggle(isOn: $edited.allowRebaseMerge) {
                    Label("Permitir rebase merging", systemImage: "arrow.triangle.branch")
                }
            }
            .disabled(!details.reportsMergeSettings)
        } header: {
            Text("Pull requests")
        } footer: {
            if !details.reportsMergeSettings {
                Text("GitHub no devolvió las opciones de merge: el token necesita permiso de administración sobre el repositorio.")
            } else if !edited.hasMergeMethod {
                Text("Debe quedar al menos un método de merge activado.").foregroundStyle(.red)
            } else if edited.pullRequestCreationPolicy == nil {
                Text("Este servidor no permite restringir quién crea pull requests.")
            } else {
                Text("«Solo colaboradores» limita la creación de pull requests a quien tiene permiso de escritura; el resto puede verlos y comentarlos.")
            }
        }
    }

    private func pagesSection(_ details: RepositoryDetails) -> some View {
        Section {
            if let pagesError {
                Label(pagesError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Picker(selection: pagesBuildType(defaultBranch: details.defaultBranch)) {
                    if originalPages == nil {
                        Text("Desactivado").tag(PagesBuildType?.none)
                    }
                    ForEach(PagesBuildType.allCases) { type in
                        Text(type.title).tag(Optional(type))
                    }
                } label: {
                    Label("Origen", systemImage: "globe")
                }

                if let pages, pages.buildType == .legacy {
                    LabeledContent {
                        TextField("Rama", text: pagesBranch, prompt: Text(details.defaultBranch))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } label: {
                        Label("Rama", systemImage: "arrow.triangle.branch")
                    }
                    Picker(selection: pagesPath) {
                        ForEach(PagesSettings.folders, id: \.self) { folder in
                            Text(folder == "/" ? "/ (root)" : folder).tag(folder)
                        }
                    } label: {
                        Label("Carpeta", systemImage: "folder")
                    }
                }

                if let url = originalPages?.htmlURL {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "safari")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        } header: {
            Text("GitHub Pages · Build and deployment")
        } footer: {
            if originalPages == nil && pages != nil {
                Text("GitHub Pages no está activado: se activará al guardar.")
            } else if pages?.buildType == .workflow {
                Text("El sitio se publica con un workflow de GitHub Actions.")
            } else if pages != nil {
                Text("El sitio se publica desde la rama y carpeta indicadas. Si la rama no existe, se crea desde el último commit de main.")
            }
        }
    }

    // MARK: - Pages bindings

    private func pagesBuildType(defaultBranch: String) -> Binding<PagesBuildType?> {
        Binding(
            get: { pages?.buildType },
            set: { newValue in
                guard let newValue else {
                    pages = nil
                    return
                }
                var updated = pages ?? originalPages ?? PagesSettings(branch: defaultBranch)
                updated.buildType = newValue
                if updated.trimmedBranch.isEmpty { updated.branch = defaultBranch }
                pages = updated
            }
        )
    }

    private var pagesBranch: Binding<String> {
        Binding(get: { pages?.branch ?? "" }, set: { pages?.branch = $0 })
    }

    private var pagesPath: Binding<String> {
        Binding(get: { pages?.path ?? "/" }, set: { pages?.path = $0 })
    }

    // MARK: - Loading and saving

    private var pagesChanged: Bool { pages != originalPages && pages != nil }

    private var hasChanges: Bool { edited != original || pagesChanged }

    private var canSave: Bool {
        guard details != nil, !isLoading, hasChanges, edited.hasMergeMethod else { return false }
        if let pages, pages.buildType == .legacy, pages.trimmedBranch.isEmpty { return false }
        return true
    }

    private func load() async {
        guard let client = state.client else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let loaded = try await client.repositoryDetails(repository)
            details = loaded
            original = loaded.settings
            edited = loaded.settings
        } catch {
            loadError = error.localizedDescription
            return
        }
        do {
            originalPages = try await client.pages(repository)
            pagesError = nil
        } catch {
            originalPages = nil
            pagesError = error.localizedDescription
        }
        pages = originalPages
    }

    private func save() async {
        guard let client = state.client, canSave else { return }
        isSaving = true
        saveError = nil
        saved = false
        defer { isSaving = false }
        do {
            if edited != original {
                try await client.updateRepositorySettings(repository, from: original, to: edited)
                original = edited
            }
            if pagesChanged, let pages {
                try await client.savePages(repository, pages, create: originalPages == nil)
            }
        } catch {
            saveError = error.localizedDescription
            return
        }
        saved = true
        await load()
    }
}
