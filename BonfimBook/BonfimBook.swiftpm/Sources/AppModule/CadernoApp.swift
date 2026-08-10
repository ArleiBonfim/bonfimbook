import SwiftUI
import CadernoCore

/// Ponto de entrada do App. No launch, monta o `BackupManager`, garante que o
/// diretório da biblioteca (`.documentDirectory`) existe e abre a `LibraryView`
/// (lista de cadernos). NÃO cria nenhum caderno automaticamente — a própria
/// `LibraryView` cuida disso (inclusive do estado vazio acolhedor).
@main
struct CadernoApp: App {
    @StateObject private var appState: AppState
    @StateObject private var backup: BackupManager

    init() {
        // Camada de backup (agente D) — assinatura `init()` sem parâmetros.
        let backup = BackupManager()

        // Garante que o diretório da biblioteca existe (não cria caderno algum).
        let library = Self.ensureLibraryDirectory()

        let state = AppState(libraryDirectory: library, backup: backup)

        _backup = StateObject(wrappedValue: backup)
        _appState = StateObject(wrappedValue: state)
    }

    var body: some Scene {
        WindowGroup {
            // A própria `LibraryView` tem seu `NavigationStack` (com o path/destinos).
            // NÃO embrulhar em outro NavigationStack aqui — aninhar quebra a navegação.
            LibraryView()
                .environmentObject(backup)
                .environmentObject(appState)
        }
    }

    // MARK: - Boot

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Garante que o diretório de Documents (onde vivem os `*.caderno`) existe e o
    /// devolve. Nenhum caderno é criado aqui — só a pasta que os conterá.
    private static func ensureLibraryDirectory() -> URL {
        let docs = documentsDirectory()
        do {
            try FileManager.default.createDirectory(at: docs,
                                                    withIntermediateDirectories: true)
        } catch {
            // Não fatal: em iOS o Documents já existe; registramos e seguimos.
            NSLog("[Caderno] Falha ao garantir o diretório da biblioteca (\(docs.path)): \(error)")
        }
        return docs
    }
}
