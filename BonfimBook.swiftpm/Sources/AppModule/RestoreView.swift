import SwiftUI
import UIKit

/// Tela "Restaurar do backup": lê os cadernos guardados na pasta de backup (iCloud/Arquivos)
/// e traz todos de volta para a biblioteca local com um toque. Nunca sobrescreve um caderno
/// existente — se houver nome repetido, cria uma cópia com sufixo "-restaurado".
///
/// Usada principalmente depois de reinstalar o app: escolhe-se a pasta do iCloud e restaura.
struct RestoreView: View {
    @ObservedObject var backup: BackupManager
    let libraryRoot: URL
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var names: [String] = []
    @State private var loading = false
    @State private var restoring = false
    @State private var error: String?
    @State private var doneCount: Int?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Restaurar do backup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fechar") { dismiss() }
                    }
                }
                .task { await loadNames() }
                // Se o usuário escolher a pasta aqui dentro, recarrega a lista automaticamente.
                .onChange(of: backup.status) { _ in
                    Task { await loadNames() }
                }
        }
    }

    // MARK: - Conteúdo por estado

    @ViewBuilder
    private var content: some View {
        if let doneCount {
            successState(doneCount)
        } else if !backup.hasFolder() {
            noFolderState
        } else if loading {
            ProgressView("Lendo o backup…")
        } else if let error {
            errorState(error)
        } else if names.isEmpty {
            emptyState
        } else {
            listState
        }
    }

    private var listState: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(names, id: \.self) { name in
                        Label(name, systemImage: "book.closed")
                    }
                } header: {
                    Text("\(names.count) caderno(s) na pasta de backup")
                } footer: {
                    Text("Restaurar traz todos de volta. Cadernos já existentes NÃO são apagados — uma cópia \u{201C}-restaurado\u{201D} é criada se houver nome repetido.")
                }
            }
            Button {
                Task { await restoreAll() }
            } label: {
                if restoring {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 28)
                } else {
                    Label("Restaurar todos", systemImage: "arrow.down.doc")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(restoring)
            .padding()
        }
    }

    private var noFolderState: some View {
        infoStack(
            icon: "externaldrive.badge.icloud",
            title: "Escolha a pasta de backup",
            message: "Para restaurar, primeiro aponte para a mesma pasta do iCloud onde seus cadernos foram guardados."
        ) {
            Button {
                chooseFolder()
            } label: {
                Label("Escolher pasta de backup", systemImage: "folder")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        infoStack(
            icon: "tray",
            title: "Nada para restaurar",
            message: "Não encontrei cadernos nessa pasta de backup. Confira se escolheu a pasta certa."
        ) {
            Button("Escolher outra pasta") { chooseFolder() }
                .buttonStyle(.bordered)
        }
    }

    private func errorState(_ message: String) -> some View {
        infoStack(
            icon: "exclamationmark.triangle",
            title: "Não consegui ler o backup",
            message: message
        ) {
            Button("Tentar de novo") { Task { await loadNames() } }
                .buttonStyle(.bordered)
        }
    }

    private func successState(_ count: Int) -> some View {
        infoStack(
            icon: "checkmark.seal.fill",
            title: "Restaurado!",
            message: "\(count) caderno(s) voltaram para a sua biblioteca."
        ) {
            Button("Concluir") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Bloco visual reutilizável (ícone + título + mensagem + ação).
    private func infoStack<A: View>(icon: String, title: String, message: String,
                                    @ViewBuilder action: () -> A) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ações

    private func loadNames() async {
        guard backup.hasFolder() else { return }
        loading = true
        error = nil
        do {
            names = try await backup.listBackupNotebooks()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func restoreAll() async {
        restoring = true
        error = nil
        do {
            let n = try await backup.restoreAll(to: libraryRoot)
            doneCount = n
            onFinished()
        } catch {
            self.error = error.localizedDescription
        }
        restoring = false
    }

    private func chooseFolder() {
        guard let vc = Self.topViewController() else {
            error = "Não consegui abrir o seletor de pasta agora."
            return
        }
        backup.chooseFolder(presenting: vc)
    }

    /// Acha a tela ativa para apresentar o seletor de pasta.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
