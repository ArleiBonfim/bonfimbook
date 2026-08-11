import XCTest
import Foundation
@testable import CadernoCore

/// Extensões da Fase 1: estilo de papel (`PaperTemplate`), compatibilidade do manifest
/// com arquivos antigos (`coverColorHex` opcional), a biblioteca de cadernos
/// (`NotebookLibrary`) e a persistência de `setTemplate`.
final class LibraryAndTemplateTests: CadernoTestCase {

    // MARK: - Helpers locais

    /// Encoder equivalente ao do Core (iso8601, chaves ordenadas), para rescrever manifests
    /// direto no disco quando o teste precisa de `updatedAt` determinísticos.
    private func writeManifestDirectly(_ manifest: Manifest, to store: NotebookStore) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try e.encode(manifest)
        try data.write(to: manifestURL(store), options: [.atomic])
    }

    // MARK: - 1. PaperTemplate: round-trip + 5 casos

    func test_paperTemplate_rawValueRoundTripAnd5Cases() throws {
        // CaseIterable tem exatamente 5 casos, nesta ordem.
        XCTAssertEqual(PaperTemplate.allCases,
                       [.blank, .ruled, .grid, .dotted, .cornell],
                       "PaperTemplate.allCases deve ter 5 casos na ordem do contrato.")
        XCTAssertEqual(PaperTemplate.allCases.count, 5)

        // rawValue estável (é o que persiste em PageMeta.template).
        let expectedRaw: [PaperTemplate: String] = [
            .blank: "blank", .ruled: "ruled", .grid: "grid",
            .dotted: "dotted", .cornell: "cornell"
        ]
        for (template, raw) in expectedRaw {
            XCTAssertEqual(template.rawValue, raw,
                           "rawValue de \(template) deve ser \"\(raw)\".")
            // Round-trip String -> enum -> String.
            XCTAssertEqual(PaperTemplate(rawValue: raw), template,
                           "PaperTemplate(rawValue: \"\(raw)\") deve reconstruir \(template).")
        }

        // displayName definido para os 5 casos (nenhum vazio).
        for template in PaperTemplate.allCases {
            XCTAssertFalse(template.displayName.isEmpty,
                           "displayName de \(template) não pode ser vazio.")
        }

        // Round-trip Codable via JSON (guarda o rawValue como String).
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for template in PaperTemplate.allCases {
            let data = try encoder.encode(template)
            let decoded = try decoder.decode(PaperTemplate.self, from: data)
            XCTAssertEqual(decoded, template,
                           "Round-trip Codable de \(template) deve preservar o caso.")
        }

        // rawValue desconhecido não vira um caso válido (não quebra, apenas nil).
        XCTAssertNil(PaperTemplate(rawValue: "hexagonal"),
                     "Um template desconhecido deve resultar em nil, não num caso inventado.")
    }

    // MARK: - 2. Manifest decodifica JSON antigo SEM coverColorHex -> nil

    func test_manifest_decodesLegacyJSONWithoutCoverColor() throws {
        // JSON de um manifest v1 (formato em disco antes do campo existir): SEM coverColorHex.
        let legacyJSON = """
        {
          "createdAt" : "2026-01-02T03:04:05Z",
          "notebookID" : "11111111-2222-3333-4444-555555555555",
          "pageOrder" : ["pg-a", "pg-b"],
          "schemaVersion" : 1,
          "title" : "Caderno Antigo",
          "updatedAt" : "2026-01-02T03:04:05Z"
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: data)

        XCTAssertNil(manifest.coverColorHex,
                     "Manifest v1 sem o campo deve decodificar com coverColorHex == nil (sem bump de schema).")
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.title, "Caderno Antigo")
        XCTAssertEqual(manifest.pageOrder, ["pg-a", "pg-b"])
    }

    // MARK: - 3. NotebookLibrary.create + list

    func test_notebookLibrary_createAndList() throws {
        // Cria 2 cadernos na biblioteca (cada create já faz 1 página).
        let s1 = try NotebookLibrary.create(in: tempDir, title: "Caderno Um", coverColorHex: "#FF0000")
        let s2 = try NotebookLibrary.create(in: tempDir, title: "Caderno Dois", coverColorHex: nil)

        XCTAssertEqual(try s1.pages().count, 1, "create deve nascer com 1 página.")
        XCTAssertEqual(try s2.pages().count, 1, "create deve nascer com 1 página.")

        // Força updatedAt determinísticos: s2 é o mais recente.
        var m1 = try s1.loadManifest()
        var m2 = try s2.loadManifest()
        m1.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)   // mais antigo
        m2.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)   // mais novo
        try writeManifestDirectly(m1, to: s1)
        try writeManifestDirectly(m2, to: s2)

        let refs = try NotebookLibrary.list(in: tempDir)

        XCTAssertEqual(refs.count, 2, "list deve enxergar os 2 cadernos criados.")

        // Ordenado por updatedAt desc: s2 (mais novo) primeiro.
        XCTAssertEqual(refs.map(\.title), ["Caderno Dois", "Caderno Um"],
                       "list deve ordenar por updatedAt desc (mais recente primeiro).")

        // pageCount correto (1 cada).
        XCTAssertEqual(refs.map(\.pageCount), [1, 1],
                       "Cada caderno recém-criado tem exatamente 1 página.")

        // coverColorHex preservado por ref.
        let byTitle = Dictionary(uniqueKeysWithValues: refs.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Caderno Um"]?.coverColorHex, "#FF0000")
        XCTAssertNil(byTitle["Caderno Dois"]?.coverColorHex)

        // As URLs apontam para pacotes .caderno reais.
        for ref in refs {
            XCTAssertEqual(ref.url.pathExtension, "caderno")
            XCTAssertTrue(FileManager.default.fileExists(atPath: ref.url.path))
        }
    }

    /// `list` é tolerante: um diretório com lixo que não é caderno (ou um pacote quebrado)
    /// não derruba a listagem.
    func test_notebookLibrary_listSkipsBrokenPackages() throws {
        _ = try NotebookLibrary.create(in: tempDir, title: "Bom", coverColorHex: nil)

        // Um pacote .caderno vazio (sem manifest) = não abre -> deve ser pulado.
        let broken = tempDir.appendingPathComponent("Quebrado.caderno", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        // Um arquivo qualquer que não é caderno.
        try Data("ruído".utf8).write(to: tempDir.appendingPathComponent("leiame.txt"))

        let refs = try NotebookLibrary.list(in: tempDir)
        XCTAssertEqual(refs.count, 1, "Apenas o caderno íntegro deve aparecer; o quebrado é pulado.")
        XCTAssertEqual(refs.first?.title, "Bom")
    }

    // MARK: - Pastas (criar / listar / mover caderno)

    func test_folders_createListAndMoveNotebook() throws {
        // Cria uma pasta na raiz.
        let folderURL = try NotebookLibrary.createFolder(in: tempDir, name: "Trabalho")
        XCTAssertEqual(try NotebookLibrary.listFolders(in: tempDir).map(\.name), ["Trabalho"])

        // Cria um caderno na raiz.
        let store = try NotebookLibrary.create(in: tempDir, title: "Mover", coverColorHex: nil)
        XCTAssertEqual(try NotebookLibrary.list(in: tempDir).count, 1)

        // Move o caderno para dentro da pasta.
        let newURL = try NotebookLibrary.move(store.packageURL, to: folderURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))

        // Raiz não tem mais cadernos; a pasta tem 1.
        XCTAssertEqual(try NotebookLibrary.list(in: tempDir).count, 0)
        XCTAssertEqual(try NotebookLibrary.list(in: folderURL).count, 1)

        // Um pacote .caderno NÃO é contado como pasta.
        XCTAssertEqual(try NotebookLibrary.listFolders(in: folderURL).count, 0)

        // Criar pasta com nome repetido não colide (ganha sufixo).
        let dup = try NotebookLibrary.createFolder(in: tempDir, name: "Trabalho")
        XCTAssertNotEqual(dup.lastPathComponent, "Trabalho")
        XCTAssertEqual(try NotebookLibrary.listFolders(in: tempDir).count, 2)
    }

    // MARK: - 4. setTemplate persiste

    func test_setTemplate_persists() throws {
        let store = try makeStore()
        let pageID = try XCTUnwrap(try store.pages().first?.id,
                                   "Deveria existir a página inicial.")

        // Página nasce com o papel padrão do app.
        XCTAssertEqual(try store.pageMeta(id: pageID).template, PaperTemplate.defaultTemplate.rawValue)

        let before = try store.loadManifest().updatedAt

        try store.setTemplate(PaperTemplate.cornell.rawValue, pageID: pageID)

        // No mesmo store, já reflete.
        XCTAssertEqual(try store.pageMeta(id: pageID).template, "cornell")

        // Reabre do zero: o template sobreviveu ao disco.
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        XCTAssertEqual(try reopened.pageMeta(id: pageID).template, "cornell",
                       "setTemplate deve persistir PageMeta.template após reabrir.")

        // Manifest foi carimbado (updatedAt >= o anterior).
        XCTAssertGreaterThanOrEqual(try reopened.loadManifest().updatedAt, before,
                                    "setTemplate deve carimbar updatedAt no manifest.")
    }
}
