import Foundation
import UIKit
import Combine
import UniformTypeIdentifiers

// Chave de UserDefaults onde guardamos o bookmark da pasta de backup escolhida.
// Fora da classe para evitar problemas de isolamento @MainActor ao ler em background.
private let backupBookmarkKey = "caderno.backupFolderBookmark"

/// Gerencia o espelhamento do pacote `.caderno` numa pasta escolhida pelo usuário
/// (camada 2 do backup) e uma exportação de segurança local (plano B).
///
/// Filosofia: nenhuma falha silenciosa. Todo erro vira `.failed(mensagem)` para que a
/// pílula de status fique vermelha e o usuário perceba.
///
// NOTA: o contrato lista a base como `ObservableObject`. Herdamos também de `NSObject`
// porque `UIDocumentPickerDelegate` exige `NSObjectProtocol`. Isso não altera a API
// pública exigida (init(), status, chooseFolder/hasFolder/mirror/exportFallback).
@MainActor
final class BackupManager: NSObject, ObservableObject {

    enum SyncStatus: Equatable {
        case noFolder            // nenhuma pasta escolhida ainda
        case idle                // pasta pronta, nada em andamento
        case syncing             // espelhando agora
        case synced(Date)        // último espelhamento OK (com a data)
        case failed(String)      // erro (mensagem legível)
    }

    @Published private(set) var status: SyncStatus

    // Fila serial em background para toda I/O de arquivo (cópia do pacote).
    private let ioQueue = DispatchQueue(label: "br.pessoal.caderno.backup", qos: .utility)

    override init() {
        // Se já existe um bookmark salvo, começamos ociosos; senão, sem pasta.
        if UserDefaults.standard.data(forKey: backupBookmarkKey) != nil {
            status = .idle
        } else {
            status = .noFolder
        }
        super.init()
    }

    // MARK: - Escolha de pasta

    /// Apresenta o seletor de PASTA. O resultado chega no delegate abaixo.
    func chooseFolder(presenting: UIViewController) {
        // asCopy = false: queremos acesso persistente à pasta real, não uma cópia.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenting.present(picker, animated: true)
    }

    /// Há uma pasta de backup configurada?
    func hasFolder() -> Bool {
        UserDefaults.standard.data(forKey: backupBookmarkKey) != nil
    }

    // MARK: - Espelhamento (camada 2)

    /// Espelha o pacote `.caderno` inteiro dentro da pasta escolhida.
    /// Sem pasta -> `.noFolder` e não faz nada. Erro -> `.failed`.
    func mirror(package: URL) {
        guard let bookmark = UserDefaults.standard.data(forKey: backupBookmarkKey) else {
            status = .noFolder
            return
        }

        status = .syncing
        let pkg = package

        ioQueue.async { [weak self] in
            do {
                // Resolve o bookmark; se ficou obsoleto, guarda a versão renovada.
                let (folder, refreshed) = try BackupManager.resolveFolder(bookmark)
                if let refreshed {
                    UserDefaults.standard.set(refreshed, forKey: backupBookmarkKey)
                }

                // Precisamos abrir o escopo de segurança para escrever na pasta do usuário.
                guard folder.startAccessingSecurityScopedResource() else {
                    throw BackupManager.makeError("Sem permissão de acesso à pasta escolhida.")
                }
                defer { folder.stopAccessingSecurityScopedResource() }

                let fm = FileManager.default
                let dest = folder.appendingPathComponent(pkg.lastPathComponent, isDirectory: true)

                // Espelhamento simples: remove o destino antigo e copia o pacote inteiro.
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: pkg, to: dest)

                let now = Date()
                // A Task captura `self` por conta própria (`[weak self]`) para não
                // referenciar o `var self` do closure de fora dentro de código que roda
                // em paralelo — o que o Swift proíbe (erro "captured var 'self'").
                Task { @MainActor [weak self] in self?.status = .synced(now) }
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor [weak self] in self?.status = .failed(msg) }
            }
        }
    }

    // MARK: - Plano B (exportação de segurança)

    /// Rede de segurança para quando o app vai a background: copia o pacote para
    /// `.documentDirectory/Exportacoes/` com timestamp no nome. Roda mesmo sem pasta
    /// escolhida (não depende do bookmark, que pode não sobreviver).
    /// Em caso de erro -> `.failed`. Em sucesso não altera o status do espelhamento
    /// (é uma cópia silenciosa de segurança, não o estado principal da pasta).
    func exportFallback(package: URL) {
        let pkg = package

        ioQueue.async { [weak self] in
            do {
                let fm = FileManager.default
                let docs = try fm.url(for: .documentDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
                let exportDir = docs.appendingPathComponent("Exportacoes", isDirectory: true)
                try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)

                // Nome: <base>-<timestamp>.caderno
                let stamp = BackupManager.timestamp(from: Date())
                let base = pkg.deletingPathExtension().lastPathComponent
                let ext = pkg.pathExtension.isEmpty ? "caderno" : pkg.pathExtension
                let dest = exportDir.appendingPathComponent("\(base)-\(stamp).\(ext)", isDirectory: true)

                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: pkg, to: dest)
                // Sucesso: cópia de segurança feita; deixamos o status como está.
            } catch {
                let msg = "Falha na exportação de segurança: \(error.localizedDescription)"
                Task { @MainActor [weak self] in self?.status = .failed(msg) }
            }
        }
    }

    // MARK: - Auxiliares (nonisolated: rodam na fila de I/O)

    /// Resolve o bookmark salvo em uma URL utilizável. Se estiver obsoleto,
    /// tenta gerar um bookmark novo e o devolve para ser regravado.
    nonisolated private static func resolveFolder(_ data: Data) throws -> (url: URL, refreshed: Data?) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [],
                          relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        var refreshed: Data? = nil
        if stale {
            // Bookmark obsoleto: regenera enquanto o escopo estiver aberto.
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                refreshed = try? url.bookmarkData(options: .minimalBookmark,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
            }
        }
        return (url, refreshed)
    }

    /// Timestamp estável e ordenável para nomes de arquivo (sem caracteres inválidos).
    nonisolated private static func timestamp(from date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return df.string(from: date)
    }

    nonisolated private static func makeError(_ message: String) -> NSError {
        NSError(domain: "br.pessoal.caderno.backup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - UIDocumentPickerDelegate

extension BackupManager: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let folder = urls.first else { return }

        // Abre o escopo, gera o bookmark de segurança e guarda; fecha ao final.
        let opened = folder.startAccessingSecurityScopedResource()
        defer { if opened { folder.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try folder.bookmarkData(options: .minimalBookmark,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: backupBookmarkKey)
            status = .idle
        } catch {
            status = .failed("Não foi possível salvar o acesso à pasta: \(error.localizedDescription)")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Usuário cancelou: mantemos o status atual (sem falha).
    }
}
