import Foundation

/// Metadados de UMA página. Vive em `pages/<id>.json`. O traço em si (bytes opacos,
/// será um PKDrawing) fica em `pages/<id>.drawing` — o Core nunca interpreta esses bytes.
public struct PageMeta: Codable, Equatable {
    public var id: String             // UUID().uuidString, == nome do arquivo (sem extensão)
    public var createdAt: Date
    public var updatedAt: Date
    public var template: String       // "blank","ruled","grid","dotted","cornell"
    // OPCIONAL de propósito (mesmo padrão de Manifest.coverColorHex): páginas antigas sem
    // este campo decodificam com nil, sem bump de schema. Quando nil/omitido, o encoder
    // não escreve a chave — arquivos antigos seguem byte-a-byte idênticos. Guarda as
    // imagens/objetos sobrepostos à página (o traço continua no arquivo .drawing à parte).
    public var elements: [PageElement]?
    // OPCIONAL, mesma regra: fundo importado (página de PDF ou imagem escaneada). nil = papel.
    public var background: PageBackground?
    // OPCIONAL, mesma regra: página marcada como favorita. nil/ausente = não favorita.
    public var favorite: Bool?
    // OPCIONAL, mesma regra: nome/título da página (para o índice). nil/ausente = sem nome.
    public var title: String?

    public init(id: String, createdAt: Date, updatedAt: Date, template: String,
                elements: [PageElement]? = nil, background: PageBackground? = nil,
                favorite: Bool? = nil, title: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.template = template
        self.elements = elements
        self.background = background
        self.favorite = favorite
        self.title = title
    }
}
