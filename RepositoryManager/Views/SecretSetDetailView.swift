import SwiftUI

struct SecretSetDetailView: View {
    @Environment(AppState.self) private var state
    @Binding var secretSet: SecretSet

    @State private var showImport = false
    @State private var confirmSend = false
    @State private var showProblems = false
    /// Secret being edited in the editor sheet (a new, empty one when adding).
    @State private var editing: SecretItem?

    var body: some View {
        Form {
            Section {
                TextField("Nombre del preset", text: $secretSet.name, prompt: Text("Ej. Producción API"))
                    .font(.headline)
            } header: {
                Text("Nombre")
            }

            destinationSection
            secretsSection
            pullRequestsSection
            pagesSection
        }
        .navigationTitle(secretSet.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editing = SecretItem()
                    } label: {
                        Label("Añadir secreto", systemImage: "plus")
                    }
                    Button {
                        showImport = true
                    } label: {
                        Label("Importar .env", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button {
                        state.duplicateSet(secretSet.id)
                    } label: {
                        Label("Duplicar preset", systemImage: "plus.square.on.square")
                    }
                } label: {
                    Label("Más", systemImage: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            sendBar
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Aplicar") {
                let id = secretSet.id
                Task { await state.upload(setID: id) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .sheet(isPresented: $showImport) {
            ImportEnvView { items in merge(items) }
        }
        .sheet(item: $editing) { item in
            SecretEditorView(
                item: item,
                isNew: !secretSet.secrets.contains(where: { $0.id == item.id }),
                otherNames: Set(secretSet.secrets.filter { $0.id != item.id }.map(\.normalizedName))
            ) { updated in
                if let index = secretSet.secrets.firstIndex(where: { $0.id == updated.id }) {
                    secretSet.secrets[index] = updated
                } else {
                    secretSet.secrets.append(updated)
                }
            }
        }
        .alert("Revisa el preset", isPresented: $showProblems) {
            Button("Aceptar") {}
        } message: {
            Text(secretSet.problems.map { "• \($0)" }.joined(separator: "\n"))
        }
    }

    // MARK: - Sections

    private var destinationSection: some View {
        Section {
            NavigationLink(value: Route.repositories(secretSet.id)) {
                LabeledContent {
                    Text(secretSet.repositories.isEmpty ? "Ninguno" : "\(secretSet.repositories.count)")
                } label: {
                    Label("Repositorios", systemImage: "book.closed")
                }
            }
            ForEach(secretSet.repositories, id: \.self) { repository in
                Label(repository, systemImage: isPrivate(repository) ? "lock" : "arrow.turn.down.right")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .swipeActions {
                        Button("Quitar", role: .destructive) {
                            secretSet.repositories.removeAll { $0 == repository }
                        }
                    }
            }

            Picker(selection: $secretSet.target) {
                ForEach(SecretTarget.allCases) { target in
                    Label(target.title, systemImage: target.systemImage).tag(target)
                }
            } label: {
                Label("Tipo de secreto", systemImage: "tray.full")
            }

            if secretSet.target == .environment {
                LabeledContent {
                    TextField("Entorno", text: $secretSet.environment, prompt: Text("production"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } label: {
                    Label("Entorno", systemImage: "server.rack")
                }
            }
        } header: {
            Text("Destino")
        } footer: {
            if secretSet.target == .environment {
                Text("Si el entorno no existe en algún repositorio, se creará al enviar.")
            } else {
                Text("Los secretos se envían a todos los repositorios seleccionados.")
            }
        }
    }

    private var secretsSection: some View {
        Section {
            ForEach(secretSet.secrets) { secret in
                Button {
                    editing = secret
                } label: {
                    SecretRow(secret: secret, isDuplicate: isDuplicate(secret))
                }
                .tint(.primary)
            }
            .onDelete { secretSet.secrets.remove(atOffsets: $0) }

            Button {
                editing = SecretItem()
            } label: {
                Label("Añadir secreto", systemImage: "plus.circle.fill")
            }
            Button {
                showImport = true
            } label: {
                Label("Importar desde .env", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Secretos (\(secretSet.secrets.count))")
        } footer: {
            Text("Los valores se guardan en el Llavero de este iPhone y se cifran con la clave pública de cada repositorio antes de enviarse.")
        }
    }

    private var pullRequestsSection: some View {
        Section {
            Toggle(isOn: appliesRepositorySettings.animation()) {
                Label("Aplicar ajustes de pull requests", systemImage: "arrow.triangle.pull")
            }
            if secretSet.repositorySettings != nil {
                Picker(selection: repositorySetting(\.pullRequestCreationPolicy, default: .all)) {
                    ForEach(PullRequestCreationPolicy.allCases) { policy in
                        Text(policy.title).tag(Optional(policy))
                    }
                } label: {
                    Label("Pueden crear pull requests", systemImage: "person.2")
                }
                Toggle(isOn: repositorySetting(\.allowMergeCommit, default: true)) {
                    Label("Permitir merge commits", systemImage: "arrow.triangle.merge")
                }
                Toggle(isOn: repositorySetting(\.allowSquashMerge, default: true)) {
                    Label("Permitir squash merging", systemImage: "square.stack.3d.down.right")
                }
                Toggle(isOn: repositorySetting(\.allowRebaseMerge, default: true)) {
                    Label("Permitir rebase merging", systemImage: "arrow.triangle.branch")
                }
            }
        } header: {
            Text("Pull requests")
        } footer: {
            if let settings = secretSet.repositorySettings, !settings.hasMergeMethod {
                Text("Debe quedar al menos un método de merge activado.").foregroundStyle(.red)
            } else if secretSet.repositorySettings != nil {
                Text("Se aplican a todos los repositorios del preset. «Solo colaboradores» limita la creación de pull requests a quien tiene permiso de escritura. Requiere ser administrador del repositorio.")
            } else {
                Text("Desactivado: no se cambian los ajustes de pull requests de los repositorios.")
            }
        }
    }

    private var pagesSection: some View {
        Section {
            Picker(selection: pagesBuildType) {
                Text("No cambiar").tag(PagesBuildType?.none)
                ForEach(PagesBuildType.allCases) { type in
                    Text(type.title).tag(Optional(type))
                }
            } label: {
                Label("Origen", systemImage: "globe")
            }
            if secretSet.pages?.buildType == .legacy {
                LabeledContent {
                    TextField("Rama", text: pagesBranch, prompt: Text("Rama por defecto"))
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
        } header: {
            Text("GitHub Pages · Build and deployment")
        } footer: {
            switch secretSet.pages?.buildType {
            case .legacy:
                Text("Los repositorios publicarán Pages desde la rama y carpeta indicadas (vacío = rama por defecto de cada uno). Si la rama no existe, se crea desde el último commit de main. Si Pages no está activado, se activa.")
            case .workflow:
                Text("Los repositorios publicarán Pages con un workflow de GitHub Actions. Si Pages no está activado, se activa.")
            case nil:
                Text("No se cambia la configuración de GitHub Pages de los repositorios.")
            }
        }
    }

    private var sendBar: some View {
        let problems = secretSet.problems
        let count = secretSet.repositories.count
        return VStack(spacing: 8) {
            if let first = problems.first {
                Button {
                    showProblems = true
                } label: {
                    Label(problems.count > 1 ? "\(first) (+\(problems.count - 1))" : first, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            } else if let lastSent = secretSet.lastSentAt {
                Label("Último envío \(lastSent.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                confirmSend = true
            } label: {
                Label(
                    count > 1 ? "Aplicar a \(count) repositorios" : "Aplicar preset",
                    systemImage: "paperplane.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!problems.isEmpty || state.isUploading)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // MARK: - Helpers

    private var confirmTitle: String {
        let repos = secretSet.repositories.count
        let reposText = repos == 1 ? secretSet.repositories.first ?? "" : "\(repos) repositorios"
        return "¿Aplicar «\(secretSet.displayName)» a \(reposText)?"
    }

    private var confirmMessage: String {
        var text = "Se aplicará: \(secretSet.actionsDescription)."
        if !secretSet.secrets.isEmpty {
            text += " Los secretos que ya existan con el mismo nombre se sobrescribirán."
        }
        return text
    }

    // MARK: - Repository settings bindings

    private var appliesRepositorySettings: Binding<Bool> {
        Binding(
            get: { secretSet.repositorySettings != nil },
            set: { secretSet.repositorySettings = $0 ? RepositorySettings(pullRequestCreationPolicy: .all) : nil }
        )
    }

    private func repositorySetting<Value>(_ keyPath: WritableKeyPath<RepositorySettings, Value>, default value: Value) -> Binding<Value> {
        Binding(
            get: { secretSet.repositorySettings?[keyPath: keyPath] ?? value },
            set: { secretSet.repositorySettings?[keyPath: keyPath] = $0 }
        )
    }

    private var pagesBuildType: Binding<PagesBuildType?> {
        Binding(
            get: { secretSet.pages?.buildType },
            set: { newValue in
                guard let newValue else {
                    secretSet.pages = nil
                    return
                }
                var pages = secretSet.pages ?? PagesSettings()
                pages.buildType = newValue
                secretSet.pages = pages
            }
        )
    }

    private var pagesBranch: Binding<String> {
        Binding(get: { secretSet.pages?.branch ?? "" }, set: { secretSet.pages?.branch = $0 })
    }

    private var pagesPath: Binding<String> {
        Binding(get: { secretSet.pages?.path ?? "/" }, set: { secretSet.pages?.path = $0 })
    }

    private func isPrivate(_ repository: String) -> Bool {
        state.repositories.first { $0.fullName.caseInsensitiveCompare(repository) == .orderedSame }?.isPrivate ?? false
    }

    private func isDuplicate(_ secret: SecretItem) -> Bool {
        let name = secret.normalizedName
        return !name.isEmpty && secretSet.secrets.filter { $0.normalizedName == name }.count > 1
    }

    /// Adds imported secrets, updating the value of those that already exist.
    private func merge(_ items: [SecretItem]) {
        secretSet.secrets.removeAll { $0.name.isEmpty && $0.value.isEmpty }
        for item in items {
            if let index = secretSet.secrets.firstIndex(where: { $0.normalizedName == item.normalizedName }) {
                secretSet.secrets[index].value = item.value
            } else {
                secretSet.secrets.append(item)
            }
        }
    }
}

private struct SecretRow: View {
    let secret: SecretItem
    let isDuplicate: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(secret.name.isEmpty ? "Sin nombre" : secret.normalizedName)
                    .font(.body.monospaced())
                    .foregroundStyle(secret.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(valueSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(problem)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var problem: String? {
        if let problem = secret.nameProblem { return problem }
        return isDuplicate ? "Nombre duplicado." : nil
    }

    private var valueSummary: String {
        if secret.value.isEmpty { return "Valor vacío" }
        let lines = secret.value.components(separatedBy: "\n").count
        if lines > 1 { return "Multilínea · \(lines) líneas" }
        return String(repeating: "•", count: min(secret.value.count, 12))
    }
}
