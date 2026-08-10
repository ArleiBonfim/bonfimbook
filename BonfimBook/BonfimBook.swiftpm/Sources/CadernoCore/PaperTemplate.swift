import Foundation

/// Estilo de papel de uma página. O `rawValue` (String) é o que persiste em
/// `PageMeta.template` — o disco continua guardando String, sem depender deste enum
/// para decodificar (páginas antigas com um template desconhecido não quebram o Core).
public enum PaperTemplate: String, CaseIterable, Codable {
    case blank, ruled, grid, dotted, cornell

    public var displayName: String {
        switch self {
        case .blank: return "Liso"
        case .ruled: return "Pautado"
        case .grid: return "Quadriculado"
        case .dotted: return "Pontilhado"
        case .cornell: return "Cornell"
        }
    }
}
