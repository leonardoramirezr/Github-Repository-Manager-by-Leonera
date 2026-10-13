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
                TextField("Nombre del conjunto", text: $secretSet.name, prompt: Text("Ej. Producción API"))
                    .font(.headline)
            } header: {
                Text("Nombre")
            }

            destinationSection
            secretsSection
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
                        Label("Duplicar conjunto", systemImage: "plus.square.on.square")
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
            Button("Enviar") {
                let id = secretSet.id
                Task { await state.upload(setID: id) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Destino: \(secretSet.destinationDescription). Los secretos que ya existan con el mismo nombre se sobrescribirán.")
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
        .alert("Revisa el conjunto", isPresented: $showProblems) {
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
                    count > 1 ? "Enviar a \(count) repositorios" : "Enviar secretos",
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
        let secrets = secretSet.secrets.count
        let repos = secretSet.repositories.count
        let secretsText = secrets == 1 ? "1 secreto" : "\(secrets) secretos"
        let reposText = repos == 1 ? secretSet.repositories.first ?? "" : "\(repos) repositorios"
        return "¿Enviar \(secretsText) a \(reposText)?"
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
