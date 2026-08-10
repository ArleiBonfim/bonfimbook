import XCTest
import Foundation
@testable import CadernoCore

/// Ciclo de vida do pacote: criação, persistência e reabertura.
/// Protege contra a perda mais grave — o caderno não voltar como estava depois de fechado.
final class NotebookLifecycleTests: CadernoTestCase {

    // MARK: - 1. createThenReload

    /// `create` deve produzir um manifest com o schema atual, exatamente 1 página,
    /// e `open` deve devolver o MESMO estado persistido em disco.
    func test_createThenReload() throws {
        let title = "Meu Caderno"
        let store = try NotebookStore.create(at: tempDir, title: title)

        // --- Estado logo após criar ---
        let manifest = try store.loadManifest()

        XCTAssertEqual(manifest.schemaVersion, CadernoSchema.current,
                       "Manifest recém-criado deve gravar schemaVersion == CadernoSchema.current (\(CadernoSchema.current)).")
        XCTAssertEqual(manifest.title, title,
                       "O título passado a create() deve ser persistido no manifest.")
        XCTAssertFalse(manifest.notebookID.isEmpty,
                       "notebookID deve ser gerado (UUID) e não vazio.")
        XCTAssertEqual(manifest.pageOrder.count, 1,
                       "Um caderno novo deve nascer com exatamente 1 página em branco.")

        let pages = try store.pages()
        XCTAssertEqual(pages.count, 1,
                       "pages() deve refletir a única página inicial.")
        XCTAssertEqual(pages.first?.id, manifest.pageOrder.first,
                       "O id da página inicial deve bater com o único elemento de pageOrder.")

        // --- Reabrir do zero e comparar ---
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        let reManifest = try reopened.loadManifest()

        XCTAssertEqual(reManifest, manifest,
                       "Reabrir com open() deve devolver um manifest idêntico ao persistido (Equatable).")
        XCTAssertEqual(try reopened.pages(), pages,
                       "Reabrir deve devolver exatamente as mesmas páginas, na mesma ordem.")
    }

    // MARK: - 2. addPagesPersist

    /// Adicionar 3 páginas e reabrir deve resultar em 4 páginas, na ordem de inserção
    /// (a página inicial primeiro, depois as três novas na ordem em que foram adicionadas).
    func test_addPagesPersist() throws {
        let store = try makeStore()

        let initialID = try XCTUnwrap(try store.pages().first?.id,
                                      "Deveria existir a página inicial antes de adicionar.")

        let added1 = try store.addPage(template: "ruled")
        let added2 = try store.addPage(template: "grid")
        let added3 = try store.addPage(template: "dotted")

        let expectedOrder = [initialID, added1.id, added2.id, added3.id]

        // Verifica em memória / disco no mesmo store.
        XCTAssertEqual(ids(try store.pages()), expectedOrder,
                       "addPage deve acrescentar ao FIM, preservando a ordem de inserção.")

        // Reabre para garantir que a ordem foi persistida, não só mantida em RAM.
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        let reloaded = try reopened.pages()

        XCTAssertEqual(reloaded.count, 4,
                       "Após reabrir, deve haver 4 páginas (1 inicial + 3 adicionadas).")
        XCTAssertEqual(ids(reloaded), expectedOrder,
                       "A ordem das páginas deve sobreviver à reabertura, idêntica.")

        // O template de cada página adicionada deve ter sido persistido.
        XCTAssertEqual(try reopened.pageMeta(id: added1.id).template, "ruled")
        XCTAssertEqual(try reopened.pageMeta(id: added2.id).template, "grid")
        XCTAssertEqual(try reopened.pageMeta(id: added3.id).template, "dotted")
    }
}
