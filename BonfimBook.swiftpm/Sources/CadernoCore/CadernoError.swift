import Foundation

/// Erros do CadernoCore. `Equatable` para facilitar asserts nos testes.
public enum CadernoError: Error, Equatable {
    /// Arquivo/recurso esperado não existe (ex.: pages/<id>.json ausente).
    case notFound(String)
    /// manifest.json existe mas não pôde ser decodificado.
    case corruptManifest
    /// pageOrder e os arquivos em disco divergem; a String descreve o quê.
    case integrityFailed(String)
    /// schemaVersion do pacote é maior que o que este binário entende.
    case unsupportedSchema(Int)
    /// Falha genérica de I/O (leitura, escrita, mover arquivo, etc.).
    case io(String)
}

extension CadernoError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let s):         return "Não encontrado: \(s)"
        case .corruptManifest:         return "manifest.json corrompido ou ilegível"
        case .integrityFailed(let s):  return "Falha de integridade: \(s)"
        case .unsupportedSchema(let v): return "Schema não suportado: versão \(v)"
        case .io(let s):               return "Erro de I/O: \(s)"
        }
    }
}
