import Foundation

/// Resumo leve de um caderno em disco, para a tela de biblioteca. Não abre o pacote
/// inteiro: carrega só o manifest para montar a "capa" (título, nº de páginas, cor, data).
public struct NotebookRef: Equatable {
    public let url: URL
    public let title: String
    public let updatedAt: Date
    public let pageCount: Int
    public let coverColorHex: String?

    public init(url: URL, title: String, updatedAt: Date, pageCount: Int, coverColorHex: String?) {
        self.url = url
        self.title = title
        self.updatedAt = updatedAt
        self.pageCount = pageCount
        self.coverColorHex = coverColorHex
    }
}

/// Operações sobre a COLEÇÃO de cadernos (a "biblioteca"), acima do `NotebookStore`
/// individual. Só Foundation — a UI vive na camada AppModule.
public enum NotebookLibrary {

    /// Extensão dos pacotes de caderno em disco.
    private static let packageExtension = "caderno"

    /// Diretório onde a biblioteca vive por padrão: a pasta Documents do app.
    public static func defaultDirectory() throws -> URL {
        let fm = FileManager.default
        do {
            return try fm.url(for: .documentDirectory,
                              in: .userDomainMask,
                              appropriateFor: nil,
                              create: true)
        } catch {
            throw CadernoError.io("não foi possível localizar o diretório de Documentos: \(error.localizedDescription)")
        }
    }

    /// Todos os `*.caderno` do diretório, lendo cada manifest, ordenados por `updatedAt` desc.
    ///
    /// Tolerante: um pacote que não abre (corrompido, manifest ilegível) é PULADO — a
    /// biblioteca inteira não pode cair por causa de um caderno ruim.
    public static func list(in directory: URL) throws -> [NotebookRef] {
        let fm = FileManager.default

        // Diretório ainda não existe (primeira execução) = biblioteca vazia, não é erro.
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: directory,
                                                  includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])
        } catch {
            throw CadernoError.io("falha ao listar a biblioteca em \(directory.lastPathComponent): \(error.localizedDescription)")
        }

        var refs: [NotebookRef] = []
        for url in contents where url.pathExtension == packageExtension {
            // best-effort: se abrir/ler o manifest falhar, ignora este pacote e segue.
            guard let store = try? NotebookStore.open(packageURL: url),
                  let manifest = try? store.loadManifest() else {
                continue
            }
            refs.append(NotebookRef(url: url,
                                    title: manifest.title,
                                    updatedAt: manifest.updatedAt,
                                    pageCount: manifest.pageOrder.count,
                                    coverColorHex: manifest.coverColorHex))
        }

        // Mais recente primeiro. Desempate estável por título para uma ordem determinística.
        refs.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return refs
    }

    /// Cria um caderno novo (delega a `NotebookStore.create`) e devolve o store aberto.
    @discardableResult
    public static func create(in directory: URL, title: String, coverColorHex: String?) throws -> NotebookStore {
        // Garante o diretório-pai da biblioteca antes de criar o pacote.
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw CadernoError.io("falha ao criar diretório da biblioteca: \(error.localizedDescription)")
            }
        }
        return try NotebookStore.create(at: directory, title: title, coverColorHex: coverColorHex)
    }

    /// Move o pacote inteiro para `<dir>/.Lixeira/<nome>-<timestampSeg>` (NÃO apaga de vez).
    /// O sufixo em segundos evita colisão se o mesmo caderno for apagado mais de uma vez.
    public static func moveToTrash(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw CadernoError.notFound(url.lastPathComponent)
        }

        let directory = url.deletingLastPathComponent()
        let trashDir = directory.appendingPathComponent(".Lixeira", isDirectory: true)

        do {
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        } catch {
            throw CadernoError.io("falha ao criar a Lixeira: \(error.localizedDescription)")
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let dest = trashDir.appendingPathComponent("\(url.lastPathComponent)-\(stamp)")

        // Colisão (mesmo segundo) é rara mas possível: limpa o destino antes do move.
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        do {
            try fm.moveItem(at: url, to: dest)
        } catch {
            throw CadernoError.io("falha ao mover \(url.lastPathComponent) para a Lixeira: \(error.localizedDescription)")
        }
    }
}
