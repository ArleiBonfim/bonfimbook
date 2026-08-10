import XCTest
import Foundation
@testable import CadernoCore

/// Formato do manifest.json em disco.
/// Protege a filosofia "Obsidian": arquivos legíveis e estáveis para recuperação
/// manual — datas em ISO8601, chaves ordenadas, round-trip Codable sem perda.
final class JSONFormatTests: CadernoTestCase {

    // MARK: - 9. jsonIsHumanReadableAndStable

    func test_jsonIsHumanReadableAndStable() throws {
        let store = try makeStore(title: "Legível")
        _ = try store.addPage(template: "cornell")

        let manifestURL = manifestURL(store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path),
                      "O manifest.json deve existir no pacote.")

        let rawData = try Data(contentsOf: manifestURL)
        let rawString = try XCTUnwrap(String(data: rawData, encoding: .utf8),
                                      "manifest.json deve ser UTF-8 legível.")

        // --- Datas em ISO8601 ---
        // Ex.: "2026-08-10T13:45:07Z". Basta uma ocorrência do padrão (createdAt/updatedAt).
        let iso8601Pattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#
        XCTAssertNotNil(rawString.range(of: iso8601Pattern, options: .regularExpression),
                        "As datas devem estar em ISO8601 (encontrado nenhum padrão AAAA-MM-DDThh:mm:ss).")

        // --- Chaves ordenadas (.sortedKeys) ---
        // Os campos de topo do Manifest, em ordem alfabética esperada.
        let expectedKeyOrder = ["createdAt", "notebookID", "pageOrder",
                                "schemaVersion", "title", "updatedAt"]
        let positions: [Int] = expectedKeyOrder.compactMap { key in
            rawString.range(of: "\"\(key)\"").map { rawString.distance(from: rawString.startIndex, to: $0.lowerBound) }
        }
        XCTAssertEqual(positions.count, expectedKeyOrder.count,
                       "Todas as chaves de topo do Manifest devem aparecer no JSON.")
        XCTAssertEqual(positions, positions.sorted(),
                       "Com .sortedKeys, as chaves devem aparecer em ordem alfabética no arquivo: \(expectedKeyOrder).")

        // --- Legibilidade: pretty-printed tem quebras de linha e indentação ---
        XCTAssertTrue(rawString.contains("\n"),
                      "O JSON deve ser pretty-printed (múltiplas linhas), não uma linha única.")

        // --- Round-trip Codable estável ---
        // Decodificar com o mesmo contrato (ISO8601) deve reproduzir o manifest que o
        // próprio store carrega — ou seja, o formato em disco é estável e sem perda.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Manifest.self, from: rawData)

        XCTAssertEqual(decoded, try store.loadManifest(),
                       "Decodificar o manifest.json cru deve reproduzir exatamente o que loadManifest() devolve (round-trip Codable sem perda).")
    }
}
