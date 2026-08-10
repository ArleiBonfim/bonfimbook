import Foundation

/// Encoder/decoder JSON configurados para o formato do caderno.
///
/// Decisões (filosofia Obsidian: arquivo legível e recuperável à mão):
///  - `.iso8601` para datas (texto estável, sem depender de locale/timezone do runner).
///  - `.prettyPrinted, .sortedKeys` para diffs limpos e leitura humana.
///
/// Devolvemos instâncias novas a cada chamada. `JSONEncoder`/`JSONDecoder` não prometem ser
/// thread-safe, e as escritas do app rodam em background (debounce) — instância por chamada
/// evita qualquer corrida por um custo desprezível.
enum CadernoJSON {
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
