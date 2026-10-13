import SwiftUI
import UniformTypeIdentifiers

/// Modal editor for a single secret (name and value, multi-line supported).
struct SecretEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: SecretItem
    @State private var reveal: Bool
    @FocusState private var nameFocused: Bool
    private let original: SecretItem
    private let isNew: Bool
    private let otherNames: Set<String>
    private let onSave: (SecretItem) -> Void

    init(item: SecretItem, isNew: Bool, otherNames: Set<String>, onSave: @escaping (SecretItem) -> Void) {
        _item = State(initialValue: item)
        original = item
        // New secrets start visible so the user can see what they type or paste.
        _reveal = State(initialValue: isNew)
        self.isNew = isNew
        self.otherNames = otherNames
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("NOMBRE_DEL_SECRETO", text: $item.name)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($nameFocused)
                } header: {
                    Text("Nombre")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("Letras, números y guion bajo. Se guarda en mayúsculas.")
                    }
                }

                Section {
                    if reveal {
                        TextEditor(text: $item.value)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .frame(minHeight: 160)
                    } else if item.value.contains("\n") {
                        Button {
                            reveal = true
                        } label: {
                            Label("Valor multilínea oculto (\(lineCount) líneas)", systemImage: "eye.slash")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        SecureField("Valor", text: $item.value)
                            .font(.body.monospaced())
                    }
                    Toggle(isOn: $reveal.animation()) {
                        Label("Mostrar valor", systemImage: "eye")
                    }
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in item.value = text }
                    }
                    .labelStyle(.titleAndIcon)
                } header: {
                    Text("Valor")
                } footer: {
                    Text("Admite varias líneas: útil para claves privadas, certificados o JSON.")
                }
            }
            .navigationTitle(isNew ? "Nuevo secreto" : "Editar secreto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Añadir" : "Guardar") {
                        item.name = item.normalizedName
                        onSave(item)
                        dismiss()
                    }
                    .bold()
                    .disabled(problem != nil || item.normalizedName.isEmpty)
                }
            }
            .onAppear {
                if isNew { nameFocused = true }
            }
        }
        // Swiping down must not silently discard changes.
        .interactiveDismissDisabled(item != original)
    }

    private var problem: String? {
        if item.name.isEmpty { return isNew ? nil : "El nombre es obligatorio." }
        if let problem = item.nameProblem { return problem }
        if otherNames.contains(item.normalizedName) { return "Ya hay otro secreto con este nombre." }
        return nil
    }

    private var lineCount: Int {
        item.value.components(separatedBy: "\n").count
    }
}

/// Paste or open `.env` content and add its variables to the set.
struct ImportEnvView: View {
    @Environment(\.dismiss) private var dismiss
    var onImport: ([SecretItem]) -> Void

    @State private var text = ""
    @State private var showFileImporter = false
    @State private var fileError: String?

    private var parsed: [SecretItem] {
        [SecretItem].parseDotEnv(text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 200)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("API_KEY=valor\nexport DB_URL=\"postgres://…\"")
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Contenido")
                } footer: {
                    Text("Formato CLAVE=valor, una por línea. Los secretos que ya existan en el conjunto actualizarán su valor.")
                }

                Section {
                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first else { return }
                        Task { @MainActor in text = pasted }
                    }
                    .labelStyle(.titleAndIcon)
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Abrir archivo…", systemImage: "folder")
                    }
                    if let fileError {
                        Label(fileError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if !parsed.isEmpty {
                    Section("Se importarán (\(parsed.count))") {
                        ForEach(parsed) { item in
                            Text(item.normalizedName)
                                .font(.subheadline.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Importar .env")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importar") {
                        onImport(parsed)
                        dismiss()
                    }
                    .bold()
                    .disabled(parsed.isEmpty)
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.plainText, .text, .data, .item]) { result in
                switch result {
                case .success(let url):
                    readFile(url)
                case .failure(let error):
                    fileError = error.localizedDescription
                }
            }
        }
    }

    private func readFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            fileError = nil
        } catch {
            fileError = "No se pudo leer el archivo como texto UTF-8."
        }
    }
}
