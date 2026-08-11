import XCTest
import Foundation
@testable import CadernoCore

/// Recursos novos do motor: renomear (`setTitle`), duplicar página (`duplicatePage`),
/// objetos/imagens sobrepostos (`setElements` + assets) e a compatibilidade do `PageMeta`
/// com arquivos antigos (campo `elements` opcional).
final class ElementsAndDuplicateTests: CadernoTestCase {

    // MARK: - PageMeta decodifica JSON antigo SEM `elements` -> nil

    func test_pageMeta_decodesLegacyJSONWithoutElements() throws {
        let legacyJSON = """
        {
          "createdAt" : "2026-01-02T03:04:05Z",
          "id" : "pg-legacy",
          "template" : "ruled",
          "updatedAt" : "2026-01-02T03:04:05Z"
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(PageMeta.self, from: data)

        XCTAssertNil(meta.elements,
                     "PageMeta antigo sem o campo deve decodificar com elements == nil (sem bump de schema).")
        XCTAssertEqual(meta.id, "pg-legacy")
        XCTAssertEqual(meta.template, "ruled")
    }

    // MARK: - setTitle

    func test_setTitle_persistsAndIgnoresEmpty() throws {
        let store = try makeStore(title: "Original")
        XCTAssertEqual(try store.loadManifest().title, "Original")

        try store.setTitle("  Meu Diário  ")   // deve aparar espaços
        XCTAssertEqual(try store.loadManifest().title, "Meu Diário")

        // Título vazio/em branco é ignorado (nunca deixa o caderno sem nome).
        try store.setTitle("   ")
        XCTAssertEqual(try store.loadManifest().title, "Meu Diário",
                       "Título em branco deve ser ignorado, mantendo o anterior.")

        // Sobrevive ao disco.
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        XCTAssertEqual(try reopened.loadManifest().title, "Meu Diário")
    }

    // MARK: - duplicatePage

    func test_duplicatePage_insertsCopyRightAfterWithDrawingAndElements() throws {
        let store = try makeStore()
        let firstID = try XCTUnwrap(try store.pages().first?.id)

        // Dá conteúdo à página original: um traço (bytes opacos) e uma imagem.
        try store.writeDrawing(Data("traço-abc".utf8), pageID: firstID)
        let assetID = try store.saveAsset(Data("bytes-da-foto".utf8), preferredExtension: "jpg")
        let element = PageElement(assetID: assetID, x: 10, y: 20, width: 100, height: 80)
        try store.setElements([element], pageID: firstID)

        // Uma segunda página, para provar que a cópia entra ENTRE as duas (logo após a 1ª).
        let second = try store.addPage(template: "grid")

        let copy = try store.duplicatePage(id: firstID)

        let order = try store.pages().map(\.id)
        XCTAssertEqual(order, [firstID, copy.id, second.id],
                       "A cópia deve entrar logo após a página de origem.")

        // Traço copiado byte-a-byte.
        XCTAssertEqual(try store.readDrawing(pageID: copy.id), Data("traço-abc".utf8),
                       "O traço deve ser copiado na duplicação.")

        // Elementos copiados (mesma referência de asset — assets são compartilhados).
        let copiedElements = try XCTUnwrap(try store.pageMeta(id: copy.id).elements)
        XCTAssertEqual(copiedElements.count, 1)
        XCTAssertEqual(copiedElements.first?.assetID, assetID)

        // Novo id e datas próprias; template herdado.
        XCTAssertNotEqual(copy.id, firstID)
        XCTAssertEqual(copy.template, try store.pageMeta(id: firstID).template)

        // Integridade preservada (sem órfãos, sem ids duplicados).
        assertNoThrow_({ try store.verifyIntegrity() })
    }

    // MARK: - setElements + assets

    func test_setElements_roundTripAndClearsWithEmpty() throws {
        let store = try makeStore()
        let pageID = try XCTUnwrap(try store.pages().first?.id)

        let assetID = try store.saveAsset(Data("foto".utf8), preferredExtension: "png")
        XCTAssertEqual(try store.readAsset(id: assetID), Data("foto".utf8),
                       "readAsset deve devolver exatamente os bytes salvos.")

        let el = PageElement(assetID: assetID, x: 1, y: 2, width: 30, height: 40, rotation: 0.5)
        try store.setElements([el], pageID: pageID)

        // Reabre do zero: elementos sobreviveram ao disco.
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        let loaded = try XCTUnwrap(try reopened.pageMeta(id: pageID).elements)
        XCTAssertEqual(loaded, [el], "Os elementos devem persistir idênticos após reabrir.")

        // Lista vazia limpa o campo (volta a nil, omitido no arquivo).
        try reopened.setElements([], pageID: pageID)
        XCTAssertNil(try reopened.pageMeta(id: pageID).elements,
                     "setElements([]) deve limpar o campo (nil), mantendo compat com arquivos antigos.")
    }

    // MARK: - PageElement round-trip Codable

    func test_pageElement_codableRoundTrip() throws {
        let el = PageElement(assetID: "abc.jpg", x: 5, y: 6, width: 7, height: 8, rotation: 1.2)
        let data = try JSONEncoder().encode(el)
        let decoded = try JSONDecoder().decode(PageElement.self, from: data)
        XCTAssertEqual(decoded, el)
        XCTAssertEqual(decoded.kind, .image)
    }

    // MARK: - PageBackground (PDF/imagem importados)

    func test_addPage_withPdfBackground_persistsAndSurvivesReopen() throws {
        let store = try makeStore()

        // Simula um PDF salvo como asset e uma página que o usa como fundo (página 2 = índice 1).
        let pdfAsset = try store.saveAsset(Data("%PDF-fake".utf8), preferredExtension: "pdf")
        let bg = PageBackground(kind: .pdf, assetID: pdfAsset, pdfPageIndex: 1)
        let page = try store.addPage(template: "blank", background: bg)

        XCTAssertEqual(page.background, bg, "addPage deve gravar o fundo informado.")

        // Reabre do zero: o fundo sobreviveu ao disco.
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        let loaded = try reopened.pageMeta(id: page.id)
        XCTAssertEqual(loaded.background, bg, "O fundo (PDF/página) deve persistir após reabrir.")
    }

    func test_pageMeta_decodesLegacyJSONWithoutBackground() throws {
        // JSON de página antiga: sem `background` nem `elements`.
        let legacyJSON = """
        {
          "createdAt" : "2026-01-02T03:04:05Z",
          "id" : "pg-old",
          "template" : "grid",
          "updatedAt" : "2026-01-02T03:04:05Z"
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(PageMeta.self, from: data)
        XCTAssertNil(meta.background, "Página antiga sem o campo deve ter background == nil.")
        XCTAssertNil(meta.elements)
    }

    func test_pageElement_textKindRoundTrip() throws {
        let el = PageElement(kind: .text, x: 10, y: 20, width: 200, height: 60,
                             text: "Olá mundo", fontSize: 22, colorHex: "#112233")
        let data = try JSONEncoder().encode(el)
        let decoded = try JSONDecoder().decode(PageElement.self, from: data)
        XCTAssertEqual(decoded, el)
        XCTAssertEqual(decoded.kind, .text)
        XCTAssertEqual(decoded.text, "Olá mundo")
        XCTAssertEqual(decoded.fontSize, 22)
        XCTAssertEqual(decoded.assetID, "", "Texto não usa asset; assetID default vazio.")
    }

    func test_pageElement_imageKind_decodesWithoutTextFields() throws {
        // Objeto de IMAGEM antigo (sem os campos de texto) deve decodificar com eles nil.
        let json = """
        {"assetID":"foto.jpg","height":80,"id":"e1","kind":"image","rotation":0,"width":100,"x":1,"y":2}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let el = try JSONDecoder().decode(PageElement.self, from: data)
        XCTAssertEqual(el.kind, .image)
        XCTAssertNil(el.text)
        XCTAssertNil(el.fontSize)
        XCTAssertNil(el.colorHex)
    }

    func test_pageBackground_imageKindRoundTrip() throws {
        let bg = PageBackground(kind: .image, assetID: "scan-1.jpg")
        let data = try JSONEncoder().encode(bg)
        let decoded = try JSONDecoder().decode(PageBackground.self, from: data)
        XCTAssertEqual(decoded, bg)
        XCTAssertNil(decoded.pdfPageIndex, "Fundo de imagem não usa índice de página de PDF.")
    }

    // MARK: - Favoritar página

    func test_setFavorite_togglesAndPersists() throws {
        let store = try makeStore()
        let pageID = try XCTUnwrap(try store.pages().first?.id)

        // Nasce sem favorito.
        XCTAssertNil(try store.pageMeta(id: pageID).favorite)

        try store.setFavorite(true, pageID: pageID)
        XCTAssertEqual(try store.pageMeta(id: pageID).favorite, true)

        // Reabre: favorito sobreviveu ao disco.
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        XCTAssertEqual(try reopened.pageMeta(id: pageID).favorite, true)

        // Desmarcar volta a nil (campo omitido, compat com arquivos antigos).
        try reopened.setFavorite(false, pageID: pageID)
        XCTAssertNil(try reopened.pageMeta(id: pageID).favorite)
    }
}
