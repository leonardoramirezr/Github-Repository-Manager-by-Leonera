import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GitHubError: LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? {
        switch statusCode {
        case 401: "Token inválido o caducado (401)."
        case 403: "Permiso denegado (403): \(message). Revisa los permisos del token."
        case 404: "No encontrado (404). Comprueba el repositorio y que el token tenga acceso a él."
        default: "GitHub respondió \(statusCode): \(message)"
        }
    }
}

struct GitHubUser: Decodable {
    let login: String
    let name: String?
}

struct RepositoryPublicKey: Decodable {
    let keyID: String
    let key: String

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case key
    }
}

/// Fields of `GET /repos/{owner}/{repo}` used by the repository settings screen.
struct RepositoryDetails: Decodable {
    let defaultBranch: String
    let permissions: Repository.Permissions?
    /// Only returned when the token can administer the repository.
    let allowMergeCommit: Bool?
    let allowSquashMerge: Bool?
    let allowRebaseMerge: Bool?
    let pullRequestCreationPolicy: String?

    enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
        case permissions
        case allowMergeCommit = "allow_merge_commit"
        case allowSquashMerge = "allow_squash_merge"
        case allowRebaseMerge = "allow_rebase_merge"
        case pullRequestCreationPolicy = "pull_request_creation_policy"
    }

    var reportsMergeSettings: Bool {
        allowMergeCommit != nil || allowSquashMerge != nil || allowRebaseMerge != nil
    }

    var settings: RepositorySettings {
        RepositorySettings(
            pullRequestCreationPolicy: pullRequestCreationPolicy.flatMap(PullRequestCreationPolicy.init(rawValue:)),
            allowMergeCommit: allowMergeCommit ?? true,
            allowSquashMerge: allowSquashMerge ?? true,
            allowRebaseMerge: allowRebaseMerge ?? true
        )
    }
}

private struct PagesSite: Decodable {
    struct Source: Decodable {
        let branch: String
        let path: String
    }

    let buildType: String?
    let source: Source?
    let htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case buildType = "build_type"
        case source
        case htmlURL = "html_url"
    }
}

/// Small REST client for the endpoints the app needs.
struct GitHubClient {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    enum PutResult {
        case created
        case updated
    }

    // MARK: - Requests

    private func url(_ segments: [String], query: [URLQueryItem] = []) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let path = segments
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + "/" + path)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// "owner/repo" → ["repos", "owner", "repo"]
    private func repoSegments(_ fullName: String) -> [String] {
        ["repos"] + fullName.split(separator: "/", maxSplits: 1).map(String.init)
    }

    private func request(
        _ method: String,
        _ url: URL,
        body: [String: Any]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RepositoryManager-iOS", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError(statusCode: 0, message: "Respuesta inesperada")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GitHubError(statusCode: http.statusCode, message: message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return (data, http)
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let (data, _) = try await request("GET", url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Endpoints

    func currentUser() async throws -> GitHubUser {
        try await get(url(["user"]), as: GitHubUser.self)
    }

    /// Every repository the token can see, optionally limited to one owner.
    func repositories(owner: String?) async throws -> [Repository] {
        var all: [Repository] = []
        let perPage = 100
        for page in 1...50 {
            let pageURL = url(["user", "repos"], query: [
                URLQueryItem(name: "per_page", value: String(perPage)),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "sort", value: "full_name"),
                URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
            ])
            let batch = try await get(pageURL, as: [Repository].self)
            all += batch
            if batch.count < perPage { break }
        }
        if let owner, !owner.isEmpty {
            all = all.filter { $0.owner.login.caseInsensitiveCompare(owner) == .orderedSame }
        }
        return all.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    private func secretsSegments(repository: String, target: SecretTarget, environment: String) -> [String] {
        let repo = repoSegments(repository)
        switch target {
        case .actions: return repo + ["actions", "secrets"]
        case .dependabot: return repo + ["dependabot", "secrets"]
        case .codespaces: return repo + ["codespaces", "secrets"]
        case .environment: return repo + ["environments", environment, "secrets"]
        }
    }

    /// Creates the environment when it does not exist yet (existing ones are left untouched).
    func ensureEnvironment(repository: String, name: String) async throws {
        let envURL = url(repoSegments(repository) + ["environments", name])
        do {
            _ = try await request("GET", envURL)
        } catch let error as GitHubError where error.statusCode == 404 {
            _ = try await request("PUT", envURL, body: [:])
        }
    }

    func publicKey(repository: String, target: SecretTarget, environment: String) async throws -> RepositoryPublicKey {
        let segments = secretsSegments(repository: repository, target: target, environment: environment)
        return try await get(url(segments + ["public-key"]), as: RepositoryPublicKey.self)
    }

    func putSecret(
        name: String,
        value: String,
        publicKey: RepositoryPublicKey,
        repository: String,
        target: SecretTarget,
        environment: String
    ) async throws -> PutResult {
        guard let keyData = Data(base64Encoded: publicKey.key) else { throw SealedBoxError.invalidPublicKey }
        let sealed = try SealedBox.seal(Array(value.utf8), recipientPublicKey: [UInt8](keyData))
        let segments = secretsSegments(repository: repository, target: target, environment: environment)
        let (_, response) = try await request("PUT", url(segments + [name]), body: [
            "encrypted_value": Data(sealed).base64EncodedString(),
            "key_id": publicKey.keyID,
        ])
        return response.statusCode == 201 ? .created : .updated
    }

    // MARK: - Repository settings

    func repositoryDetails(_ repository: String) async throws -> RepositoryDetails {
        try await get(url(repoSegments(repository)), as: RepositoryDetails.self)
    }

    /// Sends only the options that changed between `old` and `new`.
    func updateRepositorySettings(_ repository: String, from old: RepositorySettings, to new: RepositorySettings) async throws {
        var body: [String: Any] = [:]
        if new.pullRequestCreationPolicy != old.pullRequestCreationPolicy, let policy = new.pullRequestCreationPolicy {
            body["pull_request_creation_policy"] = policy.rawValue
        }
        if new.allowMergeCommit != old.allowMergeCommit { body["allow_merge_commit"] = new.allowMergeCommit }
        if new.allowSquashMerge != old.allowSquashMerge { body["allow_squash_merge"] = new.allowSquashMerge }
        if new.allowRebaseMerge != old.allowRebaseMerge { body["allow_rebase_merge"] = new.allowRebaseMerge }
        guard !body.isEmpty else { return }
        _ = try await request("PATCH", url(repoSegments(repository)), body: body)
    }

    /// GitHub Pages configuration, or nil when Pages is not enabled.
    func pages(_ repository: String) async throws -> PagesSettings? {
        let site: PagesSite
        do {
            site = try await get(url(repoSegments(repository) + ["pages"]), as: PagesSite.self)
        } catch let error as GitHubError where error.statusCode == 404 {
            return nil
        }
        return PagesSettings(
            buildType: site.buildType.flatMap(PagesBuildType.init(rawValue:)) ?? .legacy,
            branch: site.source?.branch ?? "",
            path: site.source?.path ?? "/",
            htmlURL: site.htmlURL
        )
    }

    /// Updates the build source of an existing Pages site, or enables Pages when `create` is true.
    func savePages(_ repository: String, _ pages: PagesSettings, create: Bool) async throws {
        var body: [String: Any] = ["build_type": pages.buildType.rawValue]
        if pages.buildType == .legacy {
            body["source"] = ["branch": pages.trimmedBranch, "path": pages.path]
        }
        _ = try await request(create ? "POST" : "PUT", url(repoSegments(repository) + ["pages"]), body: body)
    }
}
