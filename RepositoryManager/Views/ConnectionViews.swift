import SwiftUI

/// Token, server and account sections shared by the onboarding screen and Settings.
/// Meant to be placed inside a `Form`.
struct ConnectionSections: View {
    @Environment(AppState.self) private var state
    var submitTitle: String
    var onConnected: () -> Void = {}

    @State private var token = ""
    @State private var serverURL = ""
    @State private var account = ""
    @State private var isConnecting = false
    @State private var error: String?
    @FocusState private var focused: Field?

    private enum Field {
        case token, server, account
    }

    var body: some View {
        Section {
            SecureField(
                "Token",
                text: $token,
                prompt: Text(state.isConfigured ? "Deja vacío para mantener el actual" : "github_pat_… o ghp_…")
            )
            .focused($focused, equals: .token)
            .submitLabel(.next)
            .onSubmit { focused = .server }
        } header: {
            Text("Token de acceso personal")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Necesita permiso de escritura sobre los secretos: en un token *fine-grained*, «Secrets: Read and write» (y «Dependabot secrets», «Codespaces secrets» o «Environments» si los usas; «Administration» y «Pages» para los ajustes de repositorio); en uno clásico, el scope `repo`.")
                HStack(spacing: 16) {
                    Link("Crear fine-grained", destination: tokenURL("settings/personal-access-tokens/new"))
                    Link("Crear clásico", destination: tokenURL("settings/tokens/new?scopes=repo&description=Repository%20Manager"))
                }
                .font(.footnote.weight(.semibold))
            }
        }

        Section {
            LabeledContent("Servidor") {
                TextField("Servidor", text: $serverURL, prompt: Text("https://github.com"))
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
                    .focused($focused, equals: .server)
                    .submitLabel(.next)
                    .onSubmit { focused = .account }
            }
            LabeledContent("Cuenta") {
                TextField("Cuenta", text: $account, prompt: Text("Opcional"))
                    .multilineTextAlignment(.trailing)
                    .focused($focused, equals: .account)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
        } header: {
            Text("Conexión")
        } footer: {
            Text("La cuenta u organización (nombre o URL, p. ej. `https://github.com/mi-org`) es opcional y solo filtra la lista de repositorios. Para GitHub Enterprise Server indica la URL de tu servidor.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()

        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }

        Section {
            Button(action: submit) {
                HStack {
                    Spacer()
                    if isConnecting {
                        ProgressView()
                    } else {
                        Text(submitTitle).bold()
                    }
                    Spacer()
                }
            }
            .disabled(!canSubmit)
        }
        .onAppear {
            if serverURL.isEmpty { serverURL = state.settings.serverURL }
            if account.isEmpty { account = state.settings.account }
        }
    }

    private var canSubmit: Bool {
        !isConnecting && (state.isConfigured || !token.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func tokenURL(_ path: String) -> URL {
        var server = serverURL.trimmingCharacters(in: .whitespaces)
        if server.isEmpty { server = "https://github.com" }
        if !server.contains("://") { server = "https://" + server }
        if server.hasSuffix("/") { server.removeLast() }
        return URL(string: "\(server)/\(path)") ?? URL(string: "https://github.com/\(path)")!
    }

    private func submit() {
        guard canSubmit else { return }
        focused = nil
        isConnecting = true
        error = nil
        Task {
            defer { isConnecting = false }
            do {
                try await state.connect(token: token, serverURL: serverURL, account: account)
                token = ""
                serverURL = state.settings.serverURL
                account = state.settings.account
                onConnected()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct OnboardingView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "key.viewfinder")
                            .font(.system(size: 56, weight: .medium))
                            .foregroundStyle(.tint)
                            .symbolRenderingMode(.hierarchical)
                        Text("Repository Manager")
                            .font(.title.bold())
                        Text("Guarda presets de secretos y ajustes, y aplícalos a uno o varios repositorios de GitHub de una vez.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                ConnectionSections(submitTitle: "Conectar")

                Section {
                } footer: {
                    Label("El token se guarda en el Llavero del iPhone y solo se envía a GitHub.", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Bienvenido")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Cuenta") {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                            .symbolRenderingMode(.hierarchical)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.settings.login.isEmpty ? "Conectado" : state.settings.login)
                                .font(.headline)
                            Text(state.settings.account.isEmpty
                                 ? state.settings.hostName
                                 : "\(state.settings.hostName)/\(state.settings.account)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Repositorios", value: "\(state.repositories.count)")
                }

                ConnectionSections(submitTitle: "Guardar cambios") {
                    dismiss()
                }

                Section {
                    Button("Desconectar cuenta", role: .destructive) { confirmDisconnect = true }
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("Versión \(appVersion)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .confirmationDialog("¿Desconectar la cuenta?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Desconectar", role: .destructive) {
                    state.disconnect()
                    dismiss()
                }
            } message: {
                Text("Se borrará el token del Llavero. Tus presets se conservan.")
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
