import Foundation

/// Dono de um pacote `.caderno` em disco. Toda a lógica de persistência mora aqui.
///
/// Regras invioláveis:
///  - Importa APENAS Foundation (o traço é `Data` opaco — nunca PKDrawing).
///  - Toda escrita é ATÔMICA (temp + replace, via `Data.write(options:.atomic)`).
///  - Nunca reescrevemos o caderno inteiro: só o arquivo que mudou (+ o manifest quando a
///    ordem/updatedAt muda).
public final class NotebookStore {
    public let packageURL: URL

    private let fm = FileManager.default

    // Serializa mutações. O app salva com debounce em background; sem isso, dois writes
    // concorrentes poderiam intercalar leitura/escrita do manifest e perder páginas.
    // Recursivo porque métodos públicos chamam helpers que também travam.
    private let lock = NSRecursiveLock()

    public init(packageURL: URL) {
        self.packageURL = packageURL
    }

    // MARK: - Caminhos internos do pacote

    private var manifestURL: URL { packageURL.appendingPathComponent("manifest.json") }
    private var pagesDir: URL    { packageURL.appendingPathComponent("pages", isDirectory: true) }
    private var assetsDir: URL   { packageURL.appendingPathComponent("assets", isDirectory: true) }
    private var indexDir: URL    { packageURL.appendingPathComponent("index", isDirectory: true) }
    private var indexTextURL: URL { indexDir.appendingPathComponent("text.json") }
    private var trashDir: URL    { packageURL.appendingPathComponent(".trash", isDirectory: true) }
    private var trashJSONURL: URL { trashDir.appendingPathComponent("trash.json") }

    private func pageMetaURL(_ id: String) -> URL {
        pagesDir.appendingPathComponent(id).appendingPathExtension("json")
    }
    private func pageDrawingURL(_ id: String) -> URL {
        pagesDir.appendingPathComponent(id).appendingPathExtension("drawing")
    }
    private func trashPageDir(_ id: String) -> URL {
        trashDir.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Criar / Abrir

    /// Cria um novo pacote `.caderno` dentro de `parentDirectory`, já com 1 página em branco.
    /// `coverColorHex` (opcional, no fim) grava a cor da capa no manifest; a assinatura antiga
    /// `create(at:title:)` continua válida pelo default nil.
    public static func create(at parentDirectory: URL, title: String,
                              coverColorHex: String? = nil) throws -> NotebookStore {
        let url = packageURL(in: parentDirectory, title: title)
        let fm = FileManager.default

        // Nunca sobrescrever um pacote existente: seria perda silenciosa de dados.
        if fm.fileExists(atPath: url.path) {
            throw CadernoError.io("já existe um pacote em \(url.lastPathComponent)")
        }

        let store = NotebookStore(packageURL: url)

        do {
            // Estrutura completa do pacote.
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try fm.createDirectory(at: store.pagesDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: store.assetsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: store.indexDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: store.trashDir, withIntermediateDirectories: true)
        } catch {
            throw CadernoError.io("falha ao criar estrutura do pacote: \(error.localizedDescription)")
        }

        // index/text.json: placeholder legível da fase 0 (busca full-text vem depois).
        try store.writeJSON(IndexPlaceholder(), to: store.indexTextURL)

        // .trash/trash.json começa como lista vazia.
        try store.writeTrash([])

        // Manifest inicial, ainda sem páginas.
        let now = Date()
        let manifest = Manifest(schemaVersion: CadernoSchema.current,
                                notebookID: UUID().uuidString,
                                title: title,
                                createdAt: now,
                                updatedAt: now,
                                pageOrder: [],
                                coverColorHex: coverColorHex)
        try store.saveManifest(manifest)

        // Primeira página com o papel padrão (reusa a lógica normal, mantém invariantes).
        _ = try store.addPage(template: PaperTemplate.defaultTemplate.rawValue)

        return store
    }

    /// Abre um pacote existente. Se `schemaVersion < current`, migra e regrava o manifest.
    /// Se `schemaVersion > current`, recusa (binário velho não deve tocar arquivo novo).
    public static func open(packageURL: URL) throws -> NotebookStore {
        let fm = FileManager.default
        guard fm.fileExists(atPath: packageURL.path) else {
            throw CadernoError.notFound(packageURL.lastPathComponent)
        }
        let store = NotebookStore(packageURL: packageURL)

        let manifest = try store.loadManifest()

        if manifest.schemaVersion > CadernoSchema.current {
            throw CadernoError.unsupportedSchema(manifest.schemaVersion)
        }
        if manifest.schemaVersion < CadernoSchema.current {
            let migrated = try Migrator.migrate(manifest)
            // Regrava só o manifest (nunca o caderno inteiro).
            try store.saveManifest(migrated)
        }
        return store
    }

    // MARK: - Leitura

    public func loadManifest() throws -> Manifest {
        lock.lock(); defer { lock.unlock() }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw CadernoError.notFound("manifest.json")
        }
        do {
            return try CadernoJSON.makeDecoder().decode(Manifest.self, from: data)
        } catch {
            // Existe mas não decodifica -> corrompido (erro dedicado, não genérico).
            throw CadernoError.corruptManifest
        }
    }

    /// Páginas na ordem de `manifest.pageOrder`.
    public func pages() throws -> [PageMeta] {
        lock.lock(); defer { lock.unlock() }
        let manifest = try loadManifest()
        return try manifest.pageOrder.map { try readPageMeta($0) }
    }

    public func pageMeta(id: String) throws -> PageMeta {
        lock.lock(); defer { lock.unlock() }
        return try readPageMeta(id)
    }

    // MARK: - Mutação de páginas

    /// Acrescenta uma página ao fim e atualiza o manifest. `background` (opcional) define um
    /// fundo importado (página de PDF ou imagem escaneada); nil = papel normal do template.
    @discardableResult
    public func addPage(template: String, background: PageBackground? = nil) throws -> PageMeta {
        lock.lock(); defer { lock.unlock() }
        var manifest = try loadManifest()

        let now = Date()
        let meta = PageMeta(id: UUID().uuidString, createdAt: now, updatedAt: now,
                            template: template, background: background)

        // Ordem: escreve a meta ANTES de referenciá-la no pageOrder. Se falhar no meio,
        // sobra um arquivo órfão (detectável por verifyIntegrity), nunca um id sem arquivo.
        try writeJSON(meta, to: pageMetaURL(meta.id))

        manifest.pageOrder.append(meta.id)
        manifest.updatedAt = now
        try saveManifest(manifest)
        return meta
    }

    /// Move a página para `.trash/<id>/` (NÃO apaga) e a remove do `pageOrder`.
    public func deletePage(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var manifest = try loadManifest()
        guard let idx = manifest.pageOrder.firstIndex(of: id) else {
            throw CadernoError.notFound("página \(id) não está no pageOrder")
        }

        let dest = trashPageDir(id)
        // Se já houver lixo com esse id (raro), limpa antes para o move não falhar.
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try moveIfExists(pageMetaURL(id),   to: dest.appendingPathComponent(id).appendingPathExtension("json"))
            try moveIfExists(pageDrawingURL(id), to: dest.appendingPathComponent(id).appendingPathExtension("drawing"))
        } catch {
            throw CadernoError.io("falha ao mover página \(id) para o lixo: \(error.localizedDescription)")
        }

        // Só depois de os arquivos estarem no lixo mexemos no índice/ordem.
        var trash = try loadTrash()
        trash.append(TrashEntry(id: id, deletedAt: Date(), originalIndex: idx))
        try writeTrash(trash)

        manifest.pageOrder.remove(at: idx)
        manifest.updatedAt = Date()
        try saveManifest(manifest)
    }

    /// Restaura a página do lixo para sua posição original (ou o fim, se a posição não couber).
    public func restorePage(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var trash = try loadTrash()
        guard let tIdx = trash.firstIndex(where: { $0.id == id }) else {
            throw CadernoError.notFound("entrada de lixo para \(id)")
        }
        let entry = trash[tIdx]
        let src = trashPageDir(id)

        do {
            try moveIfExists(src.appendingPathComponent(id).appendingPathExtension("json"),    to: pageMetaURL(id))
            try moveIfExists(src.appendingPathComponent(id).appendingPathExtension("drawing"), to: pageDrawingURL(id))
        } catch {
            throw CadernoError.io("falha ao restaurar página \(id): \(error.localizedDescription)")
        }
        // Diretório do lixo deve estar vazio agora; remoção é best-effort.
        try? fm.removeItem(at: src)

        var manifest = try loadManifest()
        let clamped = min(max(0, entry.originalIndex), manifest.pageOrder.count)
        // Evita duplicar o id caso algo estranho já o tenha recolocado.
        if !manifest.pageOrder.contains(id) {
            manifest.pageOrder.insert(id, at: clamped)
        }
        manifest.updatedAt = Date()
        try saveManifest(manifest)

        trash.remove(at: tIdx)
        try writeTrash(trash)
    }

    /// Apaga DEFINITIVAMENTE entradas do lixo mais velhas que `days` dias.
    public func purgeTrash(olderThan days: Int) throws {
        lock.lock(); defer { lock.unlock() }
        var trash = try loadTrash()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)

        var kept: [TrashEntry] = []
        for entry in trash {
            if entry.deletedAt < cutoff {
                // Ponto de não-retorno: aqui os bytes somem de vez. Só entra quem passou do prazo.
                let dir = trashPageDir(entry.id)
                if fm.fileExists(atPath: dir.path) {
                    try? fm.removeItem(at: dir)
                }
            } else {
                kept.append(entry)
            }
        }
        trash = kept
        try writeTrash(trash)
    }

    /// Reordena uma página dentro do `pageOrder`.
    public func movePage(id: String, toIndex: Int) throws {
        lock.lock(); defer { lock.unlock() }
        var manifest = try loadManifest()
        guard let from = manifest.pageOrder.firstIndex(of: id) else {
            throw CadernoError.notFound("página \(id) não está no pageOrder")
        }
        manifest.pageOrder.remove(at: from)
        let clamped = min(max(0, toIndex), manifest.pageOrder.count)
        manifest.pageOrder.insert(id, at: clamped)
        manifest.updatedAt = Date()
        try saveManifest(manifest)
    }

    /// Troca o estilo de papel de uma página (grava `PageMeta.template` como String) e
    /// carimba `updatedAt` na página e no manifest. Mesmo padrão atômico de `writeDrawing`.
    public func setTemplate(_ template: String, pageID: String) throws {
        lock.lock(); defer { lock.unlock() }

        // Exige que a página exista (readPageMeta lança .notFound caso contrário).
        var meta = try readPageMeta(pageID)

        let now = Date()
        meta.template = template
        meta.updatedAt = now
        try writeJSON(meta, to: pageMetaURL(pageID))

        // Manifest também é carimbado (para backup/sync saberem que algo mudou).
        var manifest = try loadManifest()
        manifest.updatedAt = now
        try saveManifest(manifest)
    }

    /// Atualiza a cor da capa no manifest (`nil` volta ao padrão) e carimba `updatedAt`.
    public func setCoverColor(_ hex: String?) throws {
        lock.lock(); defer { lock.unlock() }
        var manifest = try loadManifest()
        manifest.coverColorHex = hex
        manifest.updatedAt = Date()
        try saveManifest(manifest)
    }

    /// Define (ou remove, com nil) o hash da senha do caderno no manifest. O Core só
    /// guarda a String opaca — quem calcula/compara o hash é a camada de UI.
    public func setLockHash(_ hash: String?) throws {
        lock.lock(); defer { lock.unlock() }
        var manifest = try loadManifest()
        manifest.lockPINHash = hash
        manifest.updatedAt = Date()
        try saveManifest(manifest)
    }

    /// Renomeia o caderno. Só troca `title` no manifest — o ARQUIVO do pacote NÃO é
    /// renomeado de propósito: a URL do pacote é usada pela navegação e pelos bookmarks de
    /// backup, e o título exibido sempre vem do manifest. Título vazio é ignorado (mantém o
    /// anterior) para nunca deixar um caderno sem nome.
    public func setTitle(_ title: String) throws {
        lock.lock(); defer { lock.unlock() }
        var manifest = try loadManifest()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manifest.title = trimmed
        manifest.updatedAt = Date()
        try saveManifest(manifest)
    }

    /// Duplica a página `id`, inserindo a cópia LOGO APÓS ela. Copia os metadados (novo id e
    /// datas), o traço (arquivo `.drawing`, se existir) e a lista de objetos/imagens — os
    /// assets em `assets/` são COMPARTILHADOS pela referência (nunca apagamos assets, então
    /// compartilhar é seguro e evita duplicar bytes de foto). Devolve a nova `PageMeta`.
    @discardableResult
    public func duplicatePage(id: String) throws -> PageMeta {
        lock.lock(); defer { lock.unlock() }
        var manifest = try loadManifest()
        guard let idx = manifest.pageOrder.firstIndex(of: id) else {
            throw CadernoError.notFound("página \(id) não está no pageOrder")
        }
        let source = try readPageMeta(id)

        let now = Date()
        let copy = PageMeta(id: UUID().uuidString,
                            createdAt: now,
                            updatedAt: now,
                            template: source.template,
                            elements: source.elements,
                            background: source.background)

        // Metadados primeiro (mesma ordem defensiva de addPage: nunca um id sem arquivo).
        try writeJSON(copy, to: pageMetaURL(copy.id))

        // Traço, se houver. Cópia direta dos bytes opacos.
        if let data = try readDrawing(pageID: id) {
            do {
                try data.write(to: pageDrawingURL(copy.id), options: [.atomic])
            } catch {
                throw CadernoError.io("falha ao copiar traço na duplicação: \(error.localizedDescription)")
            }
        }

        manifest.pageOrder.insert(copy.id, at: idx + 1)
        manifest.updatedAt = now
        try saveManifest(manifest)
        return copy
    }

    /// Marca/desmarca a página como favorita e carimba `updatedAt`. Quando `false`, gravamos
    /// `nil` (o encoder omite a chave), mantendo compat com arquivos que nunca tiveram o campo.
    public func setFavorite(_ favorite: Bool, pageID: String) throws {
        lock.lock(); defer { lock.unlock() }
        var meta = try readPageMeta(pageID)
        let now = Date()
        meta.favorite = favorite ? true : nil
        meta.updatedAt = now
        try writeJSON(meta, to: pageMetaURL(pageID))

        var manifest = try loadManifest()
        manifest.updatedAt = now
        try saveManifest(manifest)
    }

    /// Define (ou limpa, com texto vazio) o nome/título de uma página, para o índice.
    public func setPageTitle(_ title: String, pageID: String) throws {
        lock.lock(); defer { lock.unlock() }
        var meta = try readPageMeta(pageID)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        meta.title = trimmed.isEmpty ? nil : trimmed
        meta.updatedAt = now
        try writeJSON(meta, to: pageMetaURL(pageID))

        var manifest = try loadManifest()
        manifest.updatedAt = now
        try saveManifest(manifest)
    }

    // MARK: - Objetos/imagens sobrepostos à página

    /// Substitui a lista de objetos (imagens etc.) de uma página e carimba `updatedAt`.
    /// Lista vazia é gravada como `nil` (o encoder omite a chave), mantendo compatível com
    /// arquivos que nunca tiveram objetos. Mesmo padrão atômico de `writeDrawing`.
    public func setElements(_ elements: [PageElement], pageID: String) throws {
        lock.lock(); defer { lock.unlock() }
        var meta = try readPageMeta(pageID)
        let now = Date()
        meta.elements = elements.isEmpty ? nil : elements
        meta.updatedAt = now
        try writeJSON(meta, to: pageMetaURL(pageID))

        var manifest = try loadManifest()
        manifest.updatedAt = now
        try saveManifest(manifest)
    }

    /// Salva os bytes de um asset (ex.: foto) em `assets/<uuid>.<ext>` e devolve o nome do
    /// arquivo (o `assetID` que vai em `PageElement.assetID`). Escrita atômica.
    public func saveAsset(_ data: Data, preferredExtension ext: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let cleanExt = ext.trimmingCharacters(in: .whitespaces).isEmpty ? "dat" : ext
        let assetID = UUID().uuidString + "." + cleanExt
        do {
            if !fm.fileExists(atPath: assetsDir.path) {
                try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            }
            try data.write(to: assetsDir.appendingPathComponent(assetID), options: [.atomic])
        } catch {
            throw CadernoError.io("falha ao salvar asset: \(error.localizedDescription)")
        }
        return assetID
    }

    /// Bytes de um asset por `assetID`, ou `nil` se não existir.
    public func readAsset(id: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = assetsDir.appendingPathComponent(id)
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CadernoError.io("falha ao ler asset \(id): \(error.localizedDescription)")
        }
    }

    /// URL em disco de um asset (para carregar imagem direto do arquivo, sem cópia em memória).
    public func assetFileURL(id: String) -> URL {
        assetsDir.appendingPathComponent(id)
    }

    // MARK: - Traço (bytes opacos)

    /// Bytes do traço da página, ou `nil` se ela ainda não tem nenhum traço salvo.
    public func readDrawing(pageID: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = pageDrawingURL(pageID)
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CadernoError.io("falha ao ler traço de \(pageID): \(error.localizedDescription)")
        }
    }

    /// Grava o traço (atômico) e carimba `updatedAt` na PageMeta e no Manifest.
    public func writeDrawing(_ data: Data, pageID: String) throws {
        lock.lock(); defer { lock.unlock() }

        // Exige que a página exista (evita criar traço fantasma sem metadados).
        var meta = try readPageMeta(pageID)

        do {
            try data.write(to: pageDrawingURL(pageID), options: [.atomic])
        } catch {
            throw CadernoError.io("falha ao gravar traço de \(pageID): \(error.localizedDescription)")
        }

        let now = Date()
        meta.updatedAt = now
        try writeJSON(meta, to: pageMetaURL(pageID))

        // Manifest também é carimbado (para backup/sync saberem que algo mudou).
        var manifest = try loadManifest()
        manifest.updatedAt = now
        try saveManifest(manifest)
    }

    // MARK: - Integridade

    /// Confere que todo id do `pageOrder` tem `pages/<id>.json` e que não há `.json` órfão
    /// (arquivo de página fora do pageOrder). Lança `integrityFailed` com detalhe se algo bater errado.
    public func verifyIntegrity() throws {
        lock.lock(); defer { lock.unlock() }
        let manifest = try loadManifest()
        let order = manifest.pageOrder

        // Duplicatas no pageOrder quebram a correspondência 1:1 com os arquivos.
        if Set(order).count != order.count {
            throw CadernoError.integrityFailed("pageOrder contém ids duplicados")
        }

        // 1) Todo id do pageOrder precisa ter arquivo de metadados.
        for id in order where !fm.fileExists(atPath: pageMetaURL(id).path) {
            throw CadernoError.integrityFailed("página \(id) está no pageOrder mas falta pages/\(id).json")
        }

        // 2) Todo pages/*.json precisa estar no pageOrder (sem órfãos).
        let orderSet = Set(order)
        let jsonIDs = try metaFileIDsOnDisk()
        for id in jsonIDs where !orderSet.contains(id) {
            throw CadernoError.integrityFailed("arquivo pages/\(id).json é órfão (não está no pageOrder)")
        }
    }

    // MARK: - Helpers privados

    private func readPageMeta(_ id: String) throws -> PageMeta {
        let url = pageMetaURL(id)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CadernoError.notFound("pages/\(id).json")
        }
        do {
            return try CadernoJSON.makeDecoder().decode(PageMeta.self, from: data)
        } catch {
            throw CadernoError.io("pages/\(id).json ilegível: \(error.localizedDescription)")
        }
    }

    private func saveManifest(_ manifest: Manifest) throws {
        try writeJSON(manifest, to: manifestURL)
    }

    private func loadTrash() throws -> [TrashEntry] {
        guard fm.fileExists(atPath: trashJSONURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: trashJSONURL)
        } catch {
            throw CadernoError.io("falha ao ler .trash/trash.json: \(error.localizedDescription)")
        }
        do {
            return try CadernoJSON.makeDecoder().decode([TrashEntry].self, from: data)
        } catch {
            throw CadernoError.io(".trash/trash.json ilegível: \(error.localizedDescription)")
        }
    }

    private func writeTrash(_ entries: [TrashEntry]) throws {
        try writeJSON(entries, to: trashJSONURL)
    }

    /// Codifica e grava JSON de forma atômica. Único ponto de escrita de JSON do Core.
    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data: Data
        do {
            data = try CadernoJSON.makeEncoder().encode(value)
        } catch {
            throw CadernoError.io("falha ao codificar \(url.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            // .atomic escreve em arquivo temporário e faz replace — nunca deixa arquivo
            // meio-escrito visível, mesmo se o app morrer no meio.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CadernoError.io("falha ao gravar \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Move `src` para `dst` só se `src` existir. Sobrescreve `dst` se necessário.
    private func moveIfExists(_ src: URL, to dst: URL) throws {
        guard fm.fileExists(atPath: src.path) else { return }
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.moveItem(at: src, to: dst)
    }

    /// Ids derivados dos arquivos `pages/*.json` em disco (para checagem de órfãos).
    private func metaFileIDsOnDisk() throws -> [String] {
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: pagesDir,
                                                  includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])
        } catch {
            throw CadernoError.io("falha ao listar pages/: \(error.localizedDescription)")
        }
        return contents
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Monta a URL do pacote a partir de um título, com nome de arquivo seguro.
    private static func packageURL(in parent: URL, title: String) -> URL {
        let safe = sanitizedFileName(title)
        let base = safe.isEmpty ? "Caderno" : safe
        return parent.appendingPathComponent(base).appendingPathExtension("caderno")
    }

    /// Remove caracteres proibidos/perigosos em nomes de arquivo (separadores, `:`, controle).
    private static func sanitizedFileName(_ raw: String) -> String {
        var illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        illegal.formUnion(.controlCharacters)
        let cleaned = raw.components(separatedBy: illegal).joined()
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Placeholder do índice de texto da fase 0. A busca full-text real virá numa fase futura;
/// gravamos algo versionado para o arquivo já nascer legível e evoluível.
private struct IndexPlaceholder: Codable, Equatable {
    var schemaVersion: Int = CadernoSchema.current
    var pages: [String: String] = [:]
}
