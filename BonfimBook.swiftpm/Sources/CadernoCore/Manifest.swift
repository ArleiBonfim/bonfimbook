import Foundation

/// Versão do formato do pacote `.caderno`. Incrementar a cada mudança que exija
/// migração (ver `Migrator`). Nunca reutilizar um número antigo.
public enum CadernoSchema {
    public static let current: Int = 1
}

/// Índice/metadados do caderno inteiro. É o arquivo `manifest.json` na raiz do pacote.
/// `pageOrder` é a fonte da verdade da ordem de exibição das páginas.
public struct Manifest: Codable, Equatable {
    public var schemaVersion: Int
    public var notebookID: String     // UUID().uuidString
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pageOrder: [String]    // ids na ordem de exibição
    // OPCIONAL de propósito: manifests v1 (sem este campo) decodificam com nil, sem bump
    // de schema. Quando nil, o encoder omite a chave — arquivos antigos seguem idênticos.
    public var coverColorHex: String? // cor da capa; nil = padrão
    // OPCIONAL, mesma regra: hash (embaralhamento) da senha do caderno. nil = sem senha.
    // O Core NUNCA calcula nem guarda a senha em si — só armazena esta String opaca, que a
    // camada de UI produz/compara. Assim o Core segue só-Foundation (sem CryptoKit).
    public var lockPINHash: String?

    public init(schemaVersion: Int, notebookID: String, title: String,
                createdAt: Date, updatedAt: Date, pageOrder: [String],
                coverColorHex: String? = nil, lockPINHash: String? = nil) {
        self.schemaVersion = schemaVersion
        self.notebookID = notebookID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pageOrder = pageOrder
        self.coverColorHex = coverColorHex
        self.lockPINHash = lockPINHash
    }
}
