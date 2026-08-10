import Foundation

/// Metadados de UMA página. Vive em `pages/<id>.json`. O traço em si (bytes opacos,
/// será um PKDrawing) fica em `pages/<id>.drawing` — o Core nunca interpreta esses bytes.
public struct PageMeta: Codable, Equatable {
    public var id: String             // UUID().uuidString, == nome do arquivo (sem extensão)
    public var createdAt: Date
    public var updatedAt: Date
    public var template: String       // "blank","ruled","grid","dotted","cornell"

    public init(id: String, createdAt: Date, updatedAt: Date, template: String) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.template = template
    }
}
