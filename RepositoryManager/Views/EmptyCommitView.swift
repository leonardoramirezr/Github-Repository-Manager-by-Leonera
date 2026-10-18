import SwiftUI

/// Creates a commit without changes on one branch of a repository (e.g. to re-run its workflows).
struct EmptyCommitView: View {
    @Environment(AppState.self) private var state
    let repository: String
    let defaultBranch: String

    @State private var branches: [String] = []
    @State private var branch = ""
    @State private var message = "Empty commit"
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isCreating = false
    @State private var createError: String?
    @State private var created: CreatedCommit?

    var body: some View {
        Form {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Reintentar") { Task { await load() } }
                }
            } else if !branches.isEmpty {
                Section {
                    Picker(selection: $branch) {
                        ForEach(branches, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    } label: {
                        Label("Rama", systemImage: "arrow.triangle.branch")
                    }
                    .pickerStyle(.navigationLink)
                    TextField("Mensaje del commit", text: $message, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text("El commit usa el mismo contenido que el último commit de la rama, así que no modifica ningún archivo.")
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        HStack {
                            Label("Crear commit vacío", systemImage: "plus.circle.fill")
                            Spacer()
                            if isCreating { ProgressView() }
                        }
                    }
                    .disabled(!canCreate)
                }

                if let createError {
                    Section {
                        Label(createError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if let created {
                    Section {
                        Label("Commit \(created.shortSHA) creado en \(branch).", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let url = created.htmlURL {
                            Link(destination: url) {
                                Label("Ver en GitHub", systemImage: "safari")
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if isLoading && branches.isEmpty {
                ProgressView("Cargando ramas…")
            } else if !isLoading && loadError == nil && branches.isEmpty {
                ContentUnavailableView(
                    "Sin ramas",
                    systemImage: "arrow.triangle.branch",
                    description: Text("El repositorio no tiene commits todavía.")
                )
            }
        }
        .navigationTitle("Commit vacío")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: branch) { created = nil; createError = nil }
        .sensoryFeedback(.success, trigger: created?.sha) { _, new in new != nil }
    }

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canCreate: Bool {
        !isCreating && !branch.isEmpty && !trimmedMessage.isEmpty
    }

    private func load() async {
        guard let client = state.client else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            branches = try await client.branches(repository)
        } catch {
            loadError = error.localizedDescription
            return
        }
        if !branches.contains(branch) {
            branch = branches.contains(defaultBranch) ? defaultBranch : branches.first ?? ""
        }
    }

    private func create() async {
        guard let client = state.client, canCreate else { return }
        isCreating = true
        createError = nil
        created = nil
        defer { isCreating = false }
        do {
            created = try await client.createEmptyCommit(repository, branch: branch, message: trimmedMessage)
        } catch {
            createError = error.localizedDescription
        }
    }
}
