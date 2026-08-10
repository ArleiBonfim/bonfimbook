import Foundation

/// Registro de uma página apagada. Vive na lista `.trash/trash.json`.
/// `originalIndex` permite recolocar a página na posição de onde saiu ao restaurar.
public struct TrashEntry: Codable, Equatable {
    public var id: String
    public var deletedAt: Date
    public var originalIndex: Int

    public init(id: String, deletedAt: Date, originalIndex: Int) {
        self.id = id
        self.deletedAt = deletedAt
        self.originalIndex = originalIndex
    }
}
