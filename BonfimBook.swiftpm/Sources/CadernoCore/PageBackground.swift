import Foundation

/// FUNDO de uma página quando ela não é papel em branco, e sim um documento importado:
/// uma página de um PDF ou uma imagem escaneada. O traço à mão e as imagens sobrepostas
/// continuam por cima; este fundo entra no lugar do papel (`PaperTemplate`).
///
/// Como `PageElement`, os bytes NÃO ficam aqui: o PDF/imagem vive em `assets/<assetID>`
/// dentro do pacote. Guardamos só a referência e, para PDF, qual página do arquivo usar.
/// Campo OPCIONAL em `PageMeta` (compat retroativa): páginas antigas sem fundo = papel normal.
public struct PageBackground: Codable, Equatable {

    /// Tipo do fundo. `rawValue` String persiste em disco (tolerante a tipos futuros).
    public enum Kind: String, Codable {
        case pdf     // uma página de um arquivo PDF
        case image   // uma imagem (ex.: documento escaneado)
    }

    public var kind: Kind
    public var assetID: String        // arquivo em assets/ (o PDF, ou a imagem)
    public var pdfPageIndex: Int?     // para `.pdf`: índice (0-based) da página dentro do arquivo

    public init(kind: Kind, assetID: String, pdfPageIndex: Int? = nil) {
        self.kind = kind
        self.assetID = assetID
        self.pdfPageIndex = pdfPageIndex
    }
}
