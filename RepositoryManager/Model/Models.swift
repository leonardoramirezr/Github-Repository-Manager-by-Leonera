import Foundation

/// Where the secrets of a set are stored inside each repository.
enum SecretTarget: String, Codable, CaseIterable, Identifiable {
    case actions
    case dependabot
    case codespaces
    case environment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actions: "Actions"
        case .dependabot: "Dependabot"
        case .codespaces: "Codespaces"
        case .environment: "Entorno (Actions)"
        }
    }

    var systemImage: String {
        switch self {
        case .actions: "gearshape.2"
        case .dependabot: "shield.lefthalf.filled"
        case .codespaces: "laptopcomputer"
        case .environment: "server.rack"
        }
    }
}

struct SecretItem: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var value: String = ""

    /// Name as GitHub stores it (secret names are case-insensitive and upper-cased).
    var normalizedName: String {
        name.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Returns a human readable problem with the name, or nil when it is valid.
    var nameProblem: String? {
        let n = normalizedName
        if n.isEmpty { return "El nombre es obligatorio." }
        if n.hasPrefix("GITHUB_") { return "No puede empezar por GITHUB_." }
        if let first = n.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
            return "No puede empezar por un número."
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        if !n.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return "Solo letras, números y guion bajo (_)."
        }
        return nil
    }
}

/// A preset: a named, reusable group of secrets and repository settings plus the repositories
/// they are applied to.
struct SecretSet: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var secrets: [SecretItem] = []
    /// Target repositories as "owner/repo". Unlike the Mac app, a set can be sent to several at once.
    var repositories: [String] = []
    var target: SecretTarget = .actions
    var environment: String = ""
    /// Pull request settings applied to every repository; nil leaves them unchanged.
    /// Optional (like `pages`) so presets saved before these options existed still decode.
    var repositorySettings: RepositorySettings?
    /// GitHub Pages build source applied to every repository; nil leaves it unchanged.
    var pages: PagesSettings?
    var lastSentAt: Date?

    var displayName: String { name.isEmpty ? "Sin nombre" : name }

    var trimmedEnvironment: String { environment.trimmingCharacters(in: .whitespaces) }

    var destinationDescription: String {
        target == .environment ? "entorno «\(trimmedEnvironment)»" : target.title
    }

    var hasRepositoryChanges: Bool { repositorySettings != nil || pages != nil }

    /// What applying the preset changes, e.g. "3 secretos (Actions) · pull requests · GitHub Pages".
    var actionsDescription: String {
        var parts: [String] = []
        if !secrets.isEmpty {
            parts.append("\(secrets.count == 1 ? "1 secreto" : "\(secrets.count) secretos") (\(destinationDescription))")
        }
        if repositorySettings != nil { parts.append("ajustes de pull requests") }
        if let pages { parts.append("GitHub Pages: \(pages.buildType.title)") }
        return parts.joined(separator: " · ")
    }

    var repositoriesSummary: String {
        switch repositories.count {
        case 0: "Sin repositorios"
        case 1: repositories[0]
        default: "\(repositories.count) repositorios"
        }
    }

    var problems: [String] {
        var result: [String] = []
        if repositories.isEmpty { result.append("Selecciona al menos un repositorio.") }
        if secrets.isEmpty && !hasRepositoryChanges {
            result.append("Añade al menos un secreto o un ajuste de repositorio.")
        }
        if !secrets.isEmpty && target == .environment && trimmedEnvironment.isEmpty {
            result.append("Indica el nombre del entorno.")
        }
        if let repositorySettings, !repositorySettings.hasMergeMethod {
            result.append("Activa al menos un método de merge.")
        }
        for secret in secrets {
            if let problem = secret.nameProblem {
                result.append("\(secret.name.isEmpty ? "Secreto sin nombre" : secret.name): \(problem)")
            }
        }
        let names = secrets.map(\.normalizedName).filter { !$0.isEmpty }
        let duplicates = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        for name in duplicates.sorted() {
            result.append("\(name) está duplicado.")
        }
        return result
    }
}

struct Repository: Codable, Identifiable, Hashable {
    struct Owner: Codable, Hashable {
        let login: String
    }

    struct Permissions: Codable, Hashable {
        let admin: Bool?
    }

    let id: Int
    let fullName: String
    let isPrivate: Bool
    let owner: Owner
    let permissions: Permissions?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case isPrivate = "private"
        case owner
        case permissions
    }
}

/// Connection settings entered on first launch.
struct AppSettings: Codable, Equatable {
    /// Web URL of the GitHub server, e.g. https://github.com or https://github.example.com
    var serverURL: String = "https://github.com"
    /// Optional user or organization used to filter the repository list.
    var account: String = ""
    /// Login of the user the token belongs to (filled after validating the token).
    var login: String = ""

    /// Base URL of the REST API for `serverURL`.
    var apiBaseURL: URL? {
        AppSettings.apiBaseURL(for: serverURL)
    }

    var hostName: String {
        URLComponents(string: serverURL.contains("://") ? serverURL : "https://" + serverURL)?.host ?? serverURL
    }

    static func apiBaseURL(for server: String) -> URL? {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "https://github.com" }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), let host = components.host?.lowercased() else {
            return nil
        }
        let scheme = components.scheme ?? "https"
        if host == "github.com" || host == "www.github.com" || host == "api.github.com" {
            return URL(string: "https://api.github.com")
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return URL(string: "\(scheme)://\(host)\(port)/api/v3")
    }

    /// Accepts either a bare name ("my-org") or a profile URL ("https://github.com/my-org")
    /// and returns the account name and, if present, the server URL.
    static func parseAccount(_ input: String) -> (account: String, server: String?) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("/") || text.contains("://") else { return (text.replacingOccurrences(of: "@", with: ""), nil) }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: withScheme), let host = components.host else {
            return (text, nil)
        }
        let parts = components.path.split(separator: "/").map(String.init)
        // https://github.com/orgs/my-org/... → my-org
        let account = (parts.first == "orgs" && parts.count > 1) ? parts[1] : (parts.first ?? "")
        let scheme = components.scheme ?? "https"
        let port = components.port.map { ":\($0)" } ?? ""
        return (account, "\(scheme)://\(host)\(port)")
    }
}

/// Result of sending a single secret to a single repository.
struct UploadResult: Identifiable {
    enum Status {
        case pending
        case running
        case created
        case updated
        case failed(String)
    }

    let id: UUID
    let name: String
    var status: Status = .pending

    var isFinished: Bool {
        switch status {
        case .pending, .running: false
        case .created, .updated, .failed: true
        }
    }

    var isFailure: Bool {
        if case .failed = status { return true }
        return false
    }
}

/// Progress of one repository inside a multi-repository upload.
struct RepositoryUpload: Identifiable {
    let repository: String
    var results: [UploadResult]
    /// Error that prevented sending any secret (missing access, environment, public key…).
    var error: String?

    var id: String { repository }

    var isFinished: Bool { error != nil || results.allSatisfy(\.isFinished) }

    mutating func setStatus(_ status: UploadResult.Status, for id: UUID) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].status = status
    }
    var failedCount: Int { error != nil ? results.count : results.filter(\.isFailure).count }
    var succeeded: Bool { isFinished && failedCount == 0 }
}

extension Array where Element == SecretItem {
    /// Parses `.env`-style text (`KEY=value`, optional `export`, quotes and comments).
    static func parseDotEnv(_ text: String) -> [SecretItem] {
        var items: [SecretItem] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first, let last = value.last,
               first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
                if first == "\"" {
                    value = value.replacingOccurrences(of: "\\n", with: "\n")
                }
            }
            if key.isEmpty { continue }
            items.append(SecretItem(name: key, value: value))
        }
        return items
    }
}

// MARK: - Repository settings

/// Who can open pull requests (Settings › General › Features › Pull requests).
enum PullRequestCreationPolicy: String, Codable, CaseIterable, Identifiable {
    case all
    case collaboratorsOnly = "collaborators_only"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Todos los usuarios"
        case .collaboratorsOnly: "Solo colaboradores"
        }
    }
}

/// Build and deployment source of GitHub Pages.
enum PagesBuildType: String, Codable, CaseIterable, Identifiable {
    case legacy
    case workflow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .legacy: "Desde una rama"
        case .workflow: "GitHub Actions"
        }
    }
}

/// Repository options the app can edit (as returned by `GET /repos/{owner}/{repo}`).
struct RepositorySettings: Codable, Equatable, Hashable {
    /// nil when the server does not report it (e.g. older GitHub Enterprise Server).
    var pullRequestCreationPolicy: PullRequestCreationPolicy?
    var allowMergeCommit = true
    var allowSquashMerge = true
    var allowRebaseMerge = true

    var hasMergeMethod: Bool { allowMergeCommit || allowSquashMerge || allowRebaseMerge }
}

/// GitHub Pages configuration (`GET /repos/{owner}/{repo}/pages`).
struct PagesSettings: Codable, Equatable, Hashable {
    static let folders = ["/", "/docs"]

    var buildType: PagesBuildType = .legacy
    /// Branch and folder published by `.legacy` builds. In a preset, empty means the default branch.
    var branch: String = ""
    var path: String = "/"
    var htmlURL: URL?

    var trimmedBranch: String { branch.trimmingCharacters(in: .whitespaces) }
}
