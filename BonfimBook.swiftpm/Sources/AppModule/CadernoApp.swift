import SwiftUI
import CadernoCore

/// Ponto de entrada do App. No launch, abre (ou cria) o pacote `MeuCaderno.caderno`
/// em `.documentDirectory`, monta `BackupManager` + `AppState` e os injeta no ambiente.
@main
struct CadernoApp: App {
    @StateObject private var appState: AppState
    @StateObject private var backup: BackupManager

    init() {
        // Camada de backup (agente D) — assinatura `init()` sem parâmetros.
        let backup = BackupManager()

        // Abre o caderno existente, senão cria um novo com 1 página em branco.
        let store = Self.openOrCreateStore()

        // Página inicial: a primeira da ordem do manifesto. Se por algum motivo
        // o caderno vier vazio, cria uma página em branco para não abrir sem tela.
        let pageID = Self.initialPageID(for: store)

        let state = AppState(store: store, currentPageID: pageID, backup: backup)

        _backup = StateObject(wrappedValue: backup)
        _appState = StateObject(wrappedValue: state)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(backup)
        }
    }

    // MARK: - Boot

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static func openOrCreateStore() -> NotebookStore {
        let fm = FileManager.default
        let docs = documentsDirectory()

        // 1) Procura QUALQUER pacote .caderno já existente. Não dependemos de um nome
        //    fixo: o nome do arquivo é derivado do título pelo Core, então casar por
        //    extensão é o único jeito robusto de reencontrar o caderno ao reabrir o app.
        //    (Este bug — procurar por nome fixo — quebrava o app na segunda abertura.)
        let existing = (try? fm.contentsOfDirectory(at: docs,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == "caderno" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r   // mais recente primeiro
            } ?? []

        if let mostRecent = existing.first {
            do {
                return try NotebookStore.open(packageURL: mostRecent)
            } catch {
                // NOTA: não silenciamos — se o caderno existente estiver corrompido,
                // registramos alto e criamos um novo com nome que NÃO colide, preservando
                // o pacote antigo intacto no disco para recuperação manual (Obsidian).
                NSLog("[Caderno] Falha ao abrir caderno existente (\(mostRecent.lastPathComponent)): \(error). Criando novo.")
            }
        }

        // 2) Cria um caderno novo (já vem com 1 página em branco pelo contrato).
        //    Como `create` recusa sobrescrever, tentamos títulos sem colisão.
        for title in candidateTitles() {
            if let store = try? NotebookStore.create(at: docs, title: title) {
                return store
            }
        }

        // Sem caderno não há app; falha de launch precisa ser barulhenta.
        fatalError("[Caderno] Não foi possível criar um caderno em \(docs.path)")
    }

    /// "Meu Caderno", "Meu Caderno 2", ... para nunca sobrescrever um pacote existente.
    private static func candidateTitles() -> [String] {
        ["Meu Caderno"] + (2...50).map { "Meu Caderno \($0)" }
    }

    private static func initialPageID(for store: NotebookStore) -> String {
        if let first = (try? store.pages())?.first?.id {
            return first
        }
        if let created = try? store.addPage(template: "blank") {
            return created.id
        }
        // NOTA: estado impossível pelo contrato (create sempre gera 1 página).
        NSLog("[Caderno] Caderno sem páginas e addPage falhou; abrindo com id vazio.")
        return ""
    }
}
