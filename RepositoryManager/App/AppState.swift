import Foundation
import Observation

/// Screens pushed on the main navigation stack.
enum Route: Hashable {
    case set(SecretSet.ID)
    case repositories(SecretSet.ID)

    var setID: SecretSet.ID {
        switch self {
        case .set(let id), .repositories(let id): id
        }
    }
}

@MainActor
@Observable
final class AppState {
    private static let settingsKey = "settings"
    /// How many repositories are sent to at the same time.
    private static let parallelUploads = 4

    // Connection
    var settings: AppSettings
    private(set) var token: String = ""
    var isConfigured: Bool { !token.isEmpty }

    // Data
    var secretSets: [SecretSet] = []
    /// Navigation stack of the sets list.
    var path: [Route] = []
    var repositories: [Repository] = []
    var isLoadingRepositories = false
    var repositoriesError: String?

    // Upload
    var uploads: [RepositoryUpload] = []
    var uploadSetID: SecretSet.ID?
    var uploadSetName = ""
    var uploadDestination = ""
    var isUploading = false
    var showUploadSheet = false

    var storageError: String?

    private var saveTask: Task<Void, Never>?
    /// Set when the stored sets could not be read, so they are never overwritten by an empty list.
    private var loadFailed = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let stored = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = stored
        } else {
            settings = AppSettings()
        }
        do {
            if let data = try KeychainStore.read(KeychainStore.Account.token) {
                token = String(decoding: data, as: UTF8.self)
            }
            if let data = try KeychainStore.read(KeychainStore.Account.secretSets) {
                secretSets = try JSONDecoder().decode([SecretSet].self, from: data)
            }
        } catch {
            loadFailed = true
            storageError = error.localizedDescription
        }
    }

    var client: APIClient? {
        guard isConfigured, let baseURL = settings.apiBaseURL else { return nil }
        return APIClient(baseURL: baseURL, token: token)
    }

    // MARK: - Connection

    /// Validates the token against the server and stores everything on success.
    /// An empty token keeps the current one (used from Settings).
    func connect(token newToken: String, serverURL: String, account: String) async throws {
        var trimmedToken = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty { trimmedToken = token }
        let parsed = AppSettings.parseAccount(account)
        var newSettings = settings
        newSettings.serverURL = parsed.server ?? serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        newSettings.account = parsed.account
        guard let baseURL = newSettings.apiBaseURL else {
            throw APIError(statusCode: 0, message: "La URL del servidor no es válida.")
        }
        let user = try await APIClient(baseURL: baseURL, token: trimmedToken).currentUser()
        newSettings.login = user.login

        try KeychainStore.write(Data(trimmedToken.utf8), account: KeychainStore.Account.token)
        token = trimmedToken
        settings = newSettings
        if let data = try? JSONEncoder().encode(newSettings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        repositories = []
        await loadRepositories()
    }

    func disconnect() {
        try? KeychainStore.delete(KeychainStore.Account.token)
        token = ""
        repositories = []
        settings.login = ""
        path = []
    }

    // MARK: - Repositories

    func loadRepositories() async {
        guard let client else { return }
        isLoadingRepositories = true
        repositoriesError = nil
        defer { isLoadingRepositories = false }
        do {
            let owner = settings.account.isEmpty ? nil : settings.account
            repositories = try await client.repositories(owner: owner)
        } catch {
            repositoriesError = error.localizedDescription
        }
    }

    // MARK: - Secret sets

    func addSet() {
        var name = "Nuevo conjunto"
        var counter = 2
        while secretSets.contains(where: { $0.name == name }) {
            name = "Nuevo conjunto \(counter)"
            counter += 1
        }
        let set = SecretSet(name: name, secrets: [SecretItem()])
        secretSets.append(set)
        path = [.set(set.id)]
    }

    func duplicateSet(_ id: SecretSet.ID) {
        guard let original = secretSets.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " (copia)"
        copy.secrets = original.secrets.map { SecretItem(name: $0.name, value: $0.value) }
        copy.lastSentAt = nil
        if let index = secretSets.firstIndex(where: { $0.id == id }) {
            secretSets.insert(copy, at: index + 1)
        } else {
            secretSets.append(copy)
        }
    }

    func deleteSet(_ id: SecretSet.ID) {
        secretSets.removeAll { $0.id == id }
        path.removeAll { $0.setID == id }
    }

    /// Persists the secret sets to the Keychain shortly after the last change.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard !loadFailed else {
            storageError = "Los conjuntos guardados no se pudieron leer del Llavero, así que los cambios no se guardarán para no sobrescribirlos. Cierra la app por completo y vuelve a abrirla."
            return
        }
        do {
            let data = try JSONEncoder().encode(secretSets)
            try KeychainStore.write(data, account: KeychainStore.Account.secretSets)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Upload

    /// Sends every secret of the set to each of its repositories (or only to `only`, to retry).
    func upload(setID: SecretSet.ID, only: [String]? = nil) async {
        guard let client, let set = secretSets.first(where: { $0.id == setID }), !isUploading else { return }
        let targets = only ?? set.repositories
        guard !targets.isEmpty else { return }

        uploadSetID = setID
        uploadSetName = set.displayName
        uploadDestination = set.destinationDescription
        uploads = targets.map { repository in
            RepositoryUpload(
                repository: repository,
                results: set.secrets.map { UploadResult(id: $0.id, name: $0.normalizedName) }
            )
        }
        isUploading = true
        showUploadSheet = true

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func startNext() {
                guard next < targets.count else { return }
                let repository = targets[next]
                next += 1
                group.addTask { await self.send(set, to: repository, client: client) }
            }
            for _ in 0..<min(Self.parallelUploads, targets.count) { startNext() }
            while await group.next() != nil { startNext() }
        }
        isUploading = false

        let allSucceeded = uploads.allSatisfy(\.succeeded)
        if allSucceeded, only == nil, let index = secretSets.firstIndex(where: { $0.id == setID }) {
            secretSets[index].lastSentAt = Date()
            saveNow()
        }
    }

    /// Repositories of the last upload that had at least one failure.
    var failedRepositories: [String] {
        uploads.filter { $0.failedCount > 0 }.map(\.repository)
    }

    func retryFailed() async {
        guard let setID = uploadSetID else { return }
        let failed = failedRepositories
        guard !failed.isEmpty else { return }
        await upload(setID: setID, only: failed)
    }

    private func send(_ set: SecretSet, to repository: String, client: APIClient) async {
        let environment = set.trimmedEnvironment
        let key: RepositoryPublicKey
        do {
            if set.target == .environment {
                try await client.ensureEnvironment(repository: repository, name: environment)
            }
            key = try await client.publicKey(repository: repository, target: set.target, environment: environment)
        } catch {
            update(repository) { upload in
                upload.error = error.localizedDescription
                for index in upload.results.indices {
                    upload.results[index].status = .failed("No se envió")
                }
            }
            return
        }

        for (index, secret) in set.secrets.enumerated() {
            update(repository) { $0.results[index].status = .running }
            let status: UploadResult.Status
            do {
                let result = try await client.putSecret(
                    name: secret.normalizedName,
                    value: secret.value,
                    publicKey: key,
                    repository: repository,
                    target: set.target,
                    environment: environment
                )
                status = result == .created ? .created : .updated
            } catch {
                status = .failed(error.localizedDescription)
            }
            update(repository) { $0.results[index].status = status }
        }
    }

    private func update(_ repository: String, _ change: (inout RepositoryUpload) -> Void) {
        guard let index = uploads.firstIndex(where: { $0.repository == repository }) else { return }
        change(&uploads[index])
    }
}
