import XCTest
import Foundation
@testable import CadernoCore

/// Persistência dos traços (o dado mais precioso do app).
/// Protege contra corrupção de bytes e contra o salvamento incremental "vazar" para
/// outra página — que apagaria silenciosamente o desenho de um vizinho.
final class DrawingTests: CadernoTestCase {

    // MARK: - 3. drawingRoundTrip

    /// `writeDrawing` seguido de `readDrawing` devolve exatamente os mesmos bytes;
    /// uma página que nunca recebeu traço devolve nil.
    func test_drawingRoundTrip() throws {
        let store = try makeStore()
        let pageID = try XCTUnwrap(try store.pages().first?.id)

        // Página nova: sem traço ainda.
        XCTAssertNil(try store.readDrawing(pageID: pageID),
                     "Página sem nenhum traço gravado deve devolver nil (não Data vazio).")

        // Bytes propositalmente "binários" e com zero embutido, para pegar
        // qualquer tratamento errado como string.
        let payload = Data([0x00, 0x01, 0xFF, 0x10, 0x00, 0x42, 0x7F, 0x80])
        try store.writeDrawing(payload, pageID: pageID)

        let readBack = try XCTUnwrap(try store.readDrawing(pageID: pageID),
                                     "Após writeDrawing, readDrawing não deve ser nil.")
        XCTAssertEqual(readBack, payload,
                       "Os bytes lidos devem ser byte-a-byte idênticos aos gravados.")

        // Sobrescrever deve substituir integralmente (sem concatenar/append).
        let payload2 = Data([0xAA, 0xBB, 0xCC])
        try store.writeDrawing(payload2, pageID: pageID)
        XCTAssertEqual(try store.readDrawing(pageID: pageID), payload2,
                       "Reescrever o traço deve substituir totalmente o conteúdo anterior.")

        // Deve sobreviver à reabertura.
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        XCTAssertEqual(try reopened.readDrawing(pageID: pageID), payload2,
                       "O traço deve continuar íntegro após fechar e reabrir o caderno.")
    }

    // MARK: - 4. incrementalSaveIsolation

    /// Escrever o desenho da página A NÃO pode alterar o arquivo .drawing da página B.
    /// (Salvamento incremental: só o arquivo tocado muda.)
    func test_incrementalSaveIsolation() throws {
        let store = try makeStore()
        let pageA = try XCTUnwrap(try store.pages().first?.id)
        let pageB = try store.addPage(template: "blank").id

        // Dá um traço próprio à página B e captura o "antes".
        let bytesB = Data([0x11, 0x22, 0x33, 0x44, 0x55])
        try store.writeDrawing(bytesB, pageID: pageB)

        let before = try XCTUnwrap(try store.readDrawing(pageID: pageB),
                                   "B deveria ter traço antes de escrevermos em A.")
        let beforeFile = try Data(contentsOf: pageDrawingURL(store, id: pageB))

        // Escreve MUITAS vezes em A — se houvesse vazamento, apareceria aqui.
        for i in 0..<5 {
            try store.writeDrawing(Data([UInt8(0xA0 + i), 0x0F]), pageID: pageA)
        }

        // "Depois": B tem de estar intacto, tanto pela API quanto no disco cru.
        let after = try XCTUnwrap(try store.readDrawing(pageID: pageB))
        let afterFile = try Data(contentsOf: pageDrawingURL(store, id: pageB))

        XCTAssertEqual(after, before,
                       "Escrever em A não pode alterar os bytes lidos da página B.")
        XCTAssertEqual(afterFile, beforeFile,
                       "O arquivo pages/<B>.drawing em disco deve ser idêntico byte-a-byte antes e depois.")
        XCTAssertEqual(after, bytesB,
                       "E B deve continuar exatamente com o traço original que gravamos.")

        // Sanidade: A de fato mudou (o teste não é trivialmente verdadeiro).
        XCTAssertEqual(try store.readDrawing(pageID: pageA), Data([0xA4, 0x0F]),
                       "A deve refletir a última escrita — confirmando que houve escrita real em A.")
    }
}
