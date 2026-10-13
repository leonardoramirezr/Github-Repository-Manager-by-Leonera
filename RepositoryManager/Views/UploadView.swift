import SwiftUI

/// Progress and results of sending a set to one or more repositories.
struct UploadView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summaryHeader
                }

                ForEach(state.uploads) { upload in
                    Section {
                        if let error = upload.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        } else {
                            ForEach(upload.results) { result in
                                ResultRow(result: result)
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            repositoryIcon(upload)
                            Text(upload.repository)
                                .textCase(nil)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .navigationTitle(state.isUploading ? "Enviando…" : "Envío terminado")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                        .bold()
                        .disabled(state.isUploading)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !state.isUploading && !state.failedRepositories.isEmpty {
                    Button {
                        Task { await state.retryFailed() }
                    } label: {
                        Label("Reintentar \(retryTitle)", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                    .background(.bar)
                }
            }
        }
        .interactiveDismissDisabled(state.isUploading)
        .sensoryFeedback(trigger: state.isUploading) { wasUploading, isUploading in
            guard wasUploading, !isUploading else { return nil }
            return state.failedRepositories.isEmpty ? .success : .error
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: headerSymbol)
                    .font(.system(size: 36))
                    .foregroundStyle(headerColor)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.uploadSetName)
                        .font(.headline)
                    Text(state.uploadDestination)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(finished), total: Double(max(total, 1)))
                .tint(headerColor)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Counters

    private var allResults: [UploadResult] { state.uploads.flatMap(\.results) }
    private var total: Int { allResults.count }
    private var finished: Int { allResults.filter(\.isFinished).count }

    private var summary: String {
        var created = 0, updated = 0, failed = 0
        for result in allResults {
            switch result.status {
            case .created: created += 1
            case .updated: updated += 1
            case .failed: failed += 1
            default: break
            }
        }
        let repos = state.uploads.count
        var parts = [repos == 1 ? "1 repositorio" : "\(repos) repositorios"]
        if state.isUploading { parts.append("\(finished) de \(total)") }
        if created > 0 { parts.append("\(created) creado(s)") }
        if updated > 0 { parts.append("\(updated) actualizado(s)") }
        if failed > 0 { parts.append("\(failed) con error") }
        return parts.joined(separator: " · ")
    }

    private var retryTitle: String {
        let count = state.failedRepositories.count
        return count == 1 ? "1 repositorio" : "\(count) repositorios"
    }

    private var headerSymbol: String {
        if state.isUploading { return "paperplane.circle.fill" }
        return state.failedRepositories.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var headerColor: Color {
        if state.isUploading { return .accentColor }
        return state.failedRepositories.isEmpty ? .green : .orange
    }

    @ViewBuilder
    private func repositoryIcon(_ upload: RepositoryUpload) -> some View {
        if !upload.isFinished {
            ProgressView().controlSize(.mini)
        } else if upload.succeeded {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct ResultRow: View {
    let result: UploadResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.subheadline.monospaced())
                if case .failed(let message) = result.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch result.status {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .created, .updated:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var label: String {
        switch result.status {
        case .pending: "Pendiente"
        case .running: "Enviando"
        case .created: "Creado"
        case .updated: "Actualizado"
        case .failed: "Error"
        }
    }
}
