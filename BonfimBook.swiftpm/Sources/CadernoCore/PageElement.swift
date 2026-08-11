import Foundation

/// Um objeto sobreposto a uma página, além do traço à mão (que vive no arquivo `.drawing`).
///
/// Por enquanto só imagens, mas o `kind` deixa o formato pronto para caixas de texto e
/// outros tipos no futuro sem quebrar arquivos antigos. Os bytes do conteúdo (a foto)
/// NÃO ficam aqui: vivem em `assets/<assetID>` dentro do pacote; este struct guarda só a
/// referência e a geometria (posição/tamanho/rotação) no mesmo espaço de coordenadas da
/// página/canvas.
public struct PageElement: Codable, Equatable, Identifiable {

    /// Tipo do objeto. `rawValue` String persiste em disco — um tipo desconhecido lido por
    /// um app antigo é tolerado (a UI simplesmente ignora o que não sabe desenhar).
    public enum Kind: String, Codable {
        case image
        case text
        case cover   // anteparo de estudo: retângulo opaco que tampa a informação
    }

    public var id: String        // UUID().uuidString
    public var kind: Kind
    public var assetID: String   // arquivo em assets/ (imagens). Vazio "" para texto.

    // Geometria em pontos, no mesmo sistema de coordenadas do canvas (origem no topo-esquerda).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rotation: Double  // radianos; 0 = sem rotação

    // Campos de TEXTO (só usados quando kind == .text). Opcionais e compat retroativa:
    // objetos antigos (imagens) decodificam com estes nil, sem bump de schema.
    public var text: String?     // conteúdo digitado
    public var fontSize: Double? // tamanho da fonte em pontos
    public var colorHex: String? // cor do texto, ex.: "#000000"

    public init(id: String = UUID().uuidString,
                kind: Kind = .image,
                assetID: String = "",
                x: Double, y: Double,
                width: Double, height: Double,
                rotation: Double = 0,
                text: String? = nil,
                fontSize: Double? = nil,
                colorHex: String? = nil) {
        self.id = id
        self.kind = kind
        self.assetID = assetID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.text = text
        self.fontSize = fontSize
        self.colorHex = colorHex
    }
}
