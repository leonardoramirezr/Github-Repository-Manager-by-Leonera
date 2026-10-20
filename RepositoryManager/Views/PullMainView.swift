import SwiftUI

/// Pulls `main` into one branch, but only after checking that the merge would not conflict. The check runs on
/// the device (GitHub has no dry run for merges), and GitHub still refuses the merge itself if it conflicts.
struct PullMainView: View {
    @Environment(AppState.self) private var state
    let repository: String

    @State private var branches: [String] = []
    @State private var branch = ""
    @State private var isLoadingBranches = false
    @State private var loadError: String?
    @State private var status: MergeCheck.Status?
    @State private var isChecking = false
    @State private var checkError: String?
    @State private var isPulling = false
    @State private var pullError: String?
    @State private var pulledCommit: CreatedCommit?

    private static let mainBranch = "main"

    var body: some View {
        Form {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Reintentar") { Task { await loadBranches() } }
                }
            } else if !otherBranches.isEmpty {
                Section {
                    Picker(selection: $branch) {
                        ForEach(otherBranches, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    } label: {
                        Label("Rama", systemImage: "arrow.triangle.branch")
                    }
                    .pickerStyle(.navigationLink)
                    .disabled(isPulling)
                } footer: {
                    Text("Se comprueba si traer a esta rama los cambios de \(Self.mainBranch) daría conflictos.")
                }

                conflictSection
                pullSection

                if let pulledCommit {
                    Section {
                        Label("Pull hecho: commit \(pulledCommit.shortSHA) en \(branch).", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let url = pulledCommit.htmlURL {
                            Link(destination: url) {
                                Label("Ver en GitHub", systemImage: "safari")
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if isLoadingBranches && branches.isEmpty {
                ProgressView("Cargando ramas…")
            } else if !isLoadingBranches && loadError == nil && otherBranches.isEmpty {
                ContentUnavailableView(
                    "Sin otras ramas",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Solo hay ramas de \(Self.mainBranch), así que no hay nada que traer.")
                )
            }
        }
        .navigationTitle("Pull de \(Self.mainBranch)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadBranches()
            await checkConflicts()
        }
        .task { await loadBranches() }
        .task(id: branch) { await checkConflicts() }
        .onChange(of: branch) { _, _ in
            // The pull must never use a check made for another branch.
            status = nil
            pulledCommit = nil
            pullError = nil
        }
        .sensoryFeedback(.success, trigger: pulledCommit?.sha) { _, new in new != nil }
    }

    // MARK: - Sections

    private var conflictSection: some View {
        Section {
            if isChecking {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Comprobando conflictos con \(Self.mainBranch)…")
                }
            } else if let checkError {
                Label(checkError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Reintentar") { Task { await checkConflicts() } }
            } else if let status {
                statusRows(status)
            }
        } header: {
            Text("Conflictos con \(Self.mainBranch)")
        }
    }

    @ViewBuilder
    private func statusRows(_ status: MergeCheck.Status) -> some View {
        switch status {
        case .upToDate:
            Label("La rama ya tiene todos los cambios de \(Self.mainBranch).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .clean(commits, _):
            Label(
                "Sin conflictos. Hay \(commits) \(commits == 1 ? "commit" : "commits") de \(Self.mainBranch) por traer.",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case let .conflicts(paths):
            Label(
                "Hay conflictos en \(paths.count) \(paths.count == 1 ? "archivo" : "archivos"). No se puede hacer pull.",
                systemImage: "xmark.octagon.fill"
            )
            .foregroundStyle(.red)
            ForEach(paths, id: \.self) { path in
                Text(path)
                    .font(.footnote.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        case let .unverifiable(reason):
            Label(reason, systemImage: "questionmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var pullSection: some View {
        Section {
            Button {
                Task { await pull() }
            } label: {
                HStack {
                    Label("Pull de \(Self.mainBranch)", systemImage: "arrow.down.circle.fill")
                    Spacer()
                    if isPulling { ProgressView() }
                }
            }
            .disabled(!canPull)

            if let pullError {
                Label(pullError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } footer: {
            Text(pullFooter)
        }
    }

    private var pullFooter: String {
        if isChecking { return "Solo se hace pull si la comprobación no encuentra conflictos." }
        guard let status else { return "Elige una rama para comprobarla." }
        switch status {
        case .upToDate:
            return "No hay nada que traer: la rama ya tiene los cambios de \(Self.mainBranch)."
        case .clean:
            return "Trae a «\(branch)» un merge con los cambios de \(Self.mainBranch)."
        case .conflicts:
            return "No se puede hacer pull mientras haya conflictos. Resuélvelos en local y vuelve a comprobarlo."
        case .unverifiable:
            return "Sin una comprobación completa no se hace pull."
        }
    }

    // MARK: - State

    /// Every branch except main, which is what each check compares against.
    private var otherBranches: [String] {
        branches.filter { $0 != Self.mainBranch }
    }

    /// The pull is only offered after a check found no conflicts.
    private var canPull: Bool {
        guard !isChecking, !isPulling, case .clean? = status else { return false }
        return true
    }

    // MARK: - Loading and pulling

    private func loadBranches() async {
        guard let client = state.client else { return }
        isLoadingBranches = true
        loadError = nil
        defer { isLoadingBranches = false }
        do {
            branches = try await client.branches(repository)
        } catch {
            loadError = error.localizedDescription
            return
        }
        if !otherBranches.contains(branch) {
            branch = otherBranches.first ?? ""
        }
    }

    private func checkConflicts() async {
        guard !branch.isEmpty else {
            status = nil
            return
        }
        guard let client = state.client else { return }
        let checked = branch
        isChecking = true
        checkError = nil
        do {
            let result = try await client.mergeCheck(repository, branch: checked)
            // A result for a branch that is no longer selected (or a cancelled check) is dropped.
            guard !Task.isCancelled, checked == branch else { return }
            status = result
        } catch {
            guard !Task.isCancelled, checked == branch else { return }
            status = nil
            checkError = error.localizedDescription
        }
        isChecking = false
    }

    private func pull() async {
        guard let client = state.client, case let .clean(_, mainSHA)? = status else { return }
        isPulling = true
        pullError = nil
        defer { isPulling = false }
        do {
            let outcome = try await client.mergeIntoBranch(repository, branch: branch, head: mainSHA)
            switch outcome {
            case let .merged(commit):
                pulledCommit = commit
            case .alreadyUpToDate:
                break
            case .conflict:
                pullError = "GitHub no ha hecho el pull porque hay conflictos. La rama no ha cambiado."
            }
        } catch {
            pullError = error.localizedDescription
        }
        await checkConflicts()
    }
}
