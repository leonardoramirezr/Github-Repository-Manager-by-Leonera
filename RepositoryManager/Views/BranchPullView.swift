import SwiftUI

/// Pulls the changes of one branch (main by default) into another branch, as a merge made by GitHub.
struct BranchPullView: View {
    @Environment(AppState.self) private var state
    let repository: String
    let defaultBranch: String

    @State private var branches: [String] = []
    @State private var source = ""
    @State private var target = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isPulling = false
    @State private var pullError: String?
    @State private var result: BranchMergeResult?

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
                    Picker(selection: $source) {
                        ForEach(branches, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    } label: {
                        Label("Desde", systemImage: "arrow.down.circle")
                    }
                    .pickerStyle(.navigationLink)

                    Picker(selection: $target) {
                        ForEach(targets, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    } label: {
                        Label("Hacia", systemImage: "arrow.up.circle")
                    }
                    .pickerStyle(.navigationLink)
                    .disabled(targets.isEmpty)
                } header: {
                    Text("Ramas")
                } footer: {
                    if targets.isEmpty {
                        Text("El repositorio solo tiene una rama: no hay rama de destino para el pull.")
                    } else {
                        Text("Trae a «\(target)» los cambios de «\(source)» con un merge hecho en GitHub. Si hay conflictos, no se modifica nada y se indicará aquí.")
                    }
                }

                Section {
                    Button {
                        Task { await pull() }
                    } label: {
                        HStack {
                            Label("Hacer pull", systemImage: "arrow.triangle.merge")
                            Spacer()
                            if isPulling { ProgressView() }
                        }
                    }
                    .disabled(!canPull)
                }

                if let pullError {
                    Section {
                        Label(pullError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if let result {
                    Section {
                        switch result {
                        case .upToDate:
                            Label("«\(target)» ya tiene todos los cambios de «\(source)».", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        case .merged(let commit):
                            Label("Pull completado: commit \(commit.shortSHA) en \(target).", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            if let url = commit.htmlURL {
                                Link(destination: url) {
                                    Label("Ver en GitHub", systemImage: "safari")
                                }
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
        .navigationTitle("Pull")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: source) {
            if !targets.contains(target) { target = targets.first ?? "" }
            clearResult()
        }
        .onChange(of: target) { clearResult() }
    }

    /// Every branch except the source, since a branch cannot be pulled into itself.
    private var targets: [String] {
        branches.filter { $0 != source }
    }

    private var canPull: Bool {
        !isPulling && !source.isEmpty && !target.isEmpty && source != target
    }

    private func clearResult() {
        result = nil
        pullError = nil
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
        if !branches.contains(source) {
            let preferred = branches.contains("main") ? "main" : defaultBranch
            source = branches.contains(preferred) ? preferred : branches.first ?? ""
        }
        if !targets.contains(target) {
            target = targets.first ?? ""
        }
    }

    private func pull() async {
        guard let client = state.client, canPull else { return }
        isPulling = true
        clearResult()
        defer { isPulling = false }
        do {
            result = try await client.pull(repository, from: source, into: target)
        } catch {
            pullError = error.localizedDescription
        }
    }
}
