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

/// The Pages branch is missing and there is no commit to create it from (e.g. an empty repository).
struct MissingBaseBranchError: LocalizedError {
    let branch: String
    let base: String

    var errorDescription: String? {
        "La rama \(branch) no existe y no se puede crear: la rama \(base) no tiene commits."
    }
}

/// GitHub cannot merge `head` into `base` automatically. Nothing is changed on `base`.
struct MergeConflictError: LocalizedError {
    let base: String
    let head: String

    var errorDescription: String? {
        "No se puede hacer el pull: «\(head)» tiene cambios en conflicto con «\(base)». No se ha modificado nada; resuelve los conflictos en local y vuelve a intentarlo."
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

private struct GitReference: Decodable {
    struct Object: Decodable {
        let sha: String
    }

    let object: Object
}

private struct GitCommit: Decodable {
    struct Tree: Decodable {
        let sha: String
    }

    let sha: String
    let tree: Tree
    let htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case sha
        case tree
        case htmlURL = "html_url"
    }
}

private struct BranchSummary: Decodable {
    let name: String
}

/// Commit created by `createEmptyCommit`.
struct CreatedCommit {
    let sha: String
    let htmlURL: URL?

    var shortSHA: String { String(sha.prefix(7)) }
}

/// Outcome of `pull`.
enum BranchMergeResult {
    /// The target branch already contained every commit of the source branch.
    case upToDate
    case merged(CreatedCommit)
}

/// Commit returned by the merges endpoint.
private struct MergedCommit: Decodable {
    let sha: String
    let htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case sha
        case htmlURL = "html_url"
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

    /// Sets every option of `settings` (used by presets, which apply the same values to many repositories).
    func applyRepositorySettings(_ repository: String, _ settings: RepositorySettings) async throws {
        var body: [String: Any] = [
            "allow_merge_commit": settings.allowMergeCommit,
            "allow_squash_merge": settings.allowSquashMerge,
            "allow_rebase_merge": settings.allowRebaseMerge,
        ]
        if let policy = settings.pullRequestCreationPolicy {
            body["pull_request_creation_policy"] = policy.rawValue
        }
        _ = try await request("PATCH", url(repoSegments(repository)), body: body)
    }

    /// Sets the Pages build source, enabling Pages when needed. An empty branch means the default branch.
    func applyPages(_ repository: String, _ pages: PagesSettings) async throws {
        var resolved = pages
        if resolved.buildType == .legacy && resolved.trimmedBranch.isEmpty {
            resolved.branch = try await repositoryDetails(repository).defaultBranch
        }
        let current = try await self.pages(repository)
        try await savePages(repository, resolved, create: current == nil)
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
    /// A `.legacy` branch that does not exist yet is created first (see `ensureBranch`).
    func savePages(_ repository: String, _ pages: PagesSettings, create: Bool) async throws {
        var body: [String: Any] = ["build_type": pages.buildType.rawValue]
        if pages.buildType == .legacy {
            try await ensureBranch(repository, pages.trimmedBranch)
            body["source"] = ["branch": pages.trimmedBranch, "path": pages.path]
        }
        _ = try await request(create ? "POST" : "PUT", url(repoSegments(repository) + ["pages"]), body: body)
    }

    // MARK: - Branches

    /// "feature/x" → ["feature", "x"], so branch names with slashes stay readable in the path.
    private func branchSegments(_ branch: String) -> [String] {
        branch.split(separator: "/").map(String.init)
    }

    /// Latest commit of `branch`, or nil when the branch does not exist.
    func branchHead(_ repository: String, _ branch: String) async throws -> String? {
        do {
            let reference = try await get(
                url(repoSegments(repository) + ["git", "ref", "heads"] + branchSegments(branch)),
                as: GitReference.self
            )
            return reference.object.sha
        } catch let error as GitHubError where error.statusCode == 404 {
            return nil
        }
    }

    /// Creates `branch` from the latest commit of `main` (or of the default branch when there is no `main`)
    /// when it does not exist yet. Existing branches are left untouched.
    func ensureBranch(_ repository: String, _ branch: String) async throws {
        guard try await branchHead(repository, branch) == nil else { return }
        var base = "main"
        var sha = try await branchHead(repository, base)
        if sha == nil {
            base = try await repositoryDetails(repository).defaultBranch
            sha = try await branchHead(repository, base)
        }
        guard let sha else {
            throw MissingBaseBranchError(branch: branch, base: base)
        }
        _ = try await request("POST", url(repoSegments(repository) + ["git", "refs"]), body: [
            "ref": "refs/heads/\(branch)",
            "sha": sha,
        ])
    }

    /// Names of every branch of the repository.
    func branches(_ repository: String) async throws -> [String] {
        var all: [String] = []
        let perPage = 100
        for page in 1...50 {
            let pageURL = url(repoSegments(repository) + ["branches"], query: [
                URLQueryItem(name: "per_page", value: String(perPage)),
                URLQueryItem(name: "page", value: String(page)),
            ])
            let batch = try await get(pageURL, as: [BranchSummary].self)
            all += batch.map(\.name)
            if batch.count < perPage { break }
        }
        return all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Adds a commit without changes (same tree as the current head) on top of `branch`.
    /// The branch is only fast-forwarded: if someone pushed meanwhile GitHub rejects the update.
    func createEmptyCommit(_ repository: String, branch: String, message: String) async throws -> CreatedCommit {
        let git = repoSegments(repository) + ["git"]
        guard let head = try await branchHead(repository, branch) else {
            throw GitHubError(statusCode: 404, message: "La rama \(branch) no existe")
        }
        let parent = try await get(url(git + ["commits", head]), as: GitCommit.self)
        let (data, _) = try await request("POST", url(git + ["commits"]), body: [
            "message": message,
            "tree": parent.tree.sha,
            "parents": [head],
        ])
        let commit = try JSONDecoder().decode(GitCommit.self, from: data)
        _ = try await request("PATCH", url(git + ["refs", "heads"] + branchSegments(branch)), body: [
            "sha": commit.sha,
            "force": false,
        ])
        return CreatedCommit(sha: commit.sha, htmlURL: commit.htmlURL)
    }

    /// Merges `source` into `target` on GitHub (a "pull" between branches), creating a merge commit on `target`.
    /// Throws `MergeConflictError` when the changes conflict.
    func pull(_ repository: String, from source: String, into target: String) async throws -> BranchMergeResult {
        do {
            let (data, response) = try await request("POST", url(repoSegments(repository) + ["merges"]), body: [
                "base": target,
                "head": source,
            ])
            if response.statusCode == 204 { return .upToDate }
            let merged = try JSONDecoder().decode(MergedCommit.self, from: data)
            return .merged(CreatedCommit(sha: merged.sha, htmlURL: merged.htmlURL))
        } catch let error as GitHubError where error.statusCode == 409 {
            throw MergeConflictError(base: target, head: source)
        }
    }
}
