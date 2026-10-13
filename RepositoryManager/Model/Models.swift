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
        case .actions: "Flujos de trabajo (CI)"
        case .dependabot: "Actualización de dependencias"
        case .codespaces: "Entornos de desarrollo"
        case .environment: "Entorno de despliegue"
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

    /// Name as the server stores it (secret names are case-insensitive and upper-cased).
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

/// A named, reusable group of secrets plus the repositories they are sent to.
struct SecretSet: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var secrets: [SecretItem] = []
    /// Target repositories as "owner/repo". Unlike the Mac app, a set can be sent to several at once.
    var repositories: [String] = []
    var target: SecretTarget = .actions
    var environment: String = ""
    var lastSentAt: Date?

    var displayName: String { name.isEmpty ? "Sin nombre" : name }

    var trimmedEnvironment: String { environment.trimmingCharacters(in: .whitespaces) }

    var destinationDescription: String {
        target == .environment ? "entorno «\(trimmedEnvironment)»" : target.title
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
        if secrets.isEmpty { result.append("Añade al menos un secreto.") }
        if target == .environment && trimmedEnvironment.isEmpty {
            result.append("Indica el nombre del entorno.")
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
    /// Web URL of the server (the default host, or a self-hosted one such as https://git.example.com).
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

    /// Accepts either a bare name ("my-org") or a profile URL ("https://host/my-org")
    /// and returns the account name and, if present, the server URL.
    static func parseAccount(_ input: String) -> (account: String, server: String?) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("/") || text.contains("://") else { return (text.replacingOccurrences(of: "@", with: ""), nil) }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: withScheme), let host = components.host else {
            return (text, nil)
        }
        let parts = components.path.split(separator: "/").map(String.init)
        // https://host/orgs/my-org/... → my-org
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
