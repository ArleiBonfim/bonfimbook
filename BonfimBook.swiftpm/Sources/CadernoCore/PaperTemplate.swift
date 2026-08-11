import Foundation

/// Estilo de papel de uma página. O `rawValue` (String) é o que persiste em
/// `PageMeta.template` — o disco continua guardando String, sem depender deste enum
/// para decodificar (páginas antigas com um template desconhecido não quebram o Core).
public enum PaperTemplate: String, CaseIterable, Codable {
    case blank, ruled, grid, dotted, cornell

    /// Papel padrão de páginas/cadernos novos. Centralizado aqui: mudar só esta linha muda
    /// o padrão em todo o app (motor, UI e testes referenciam este valor).
    public static let defaultTemplate: PaperTemplate = .grid

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
