import XCTest
import Foundation
@testable import CadernoCore

/// Apagar/restaurar e reordenar páginas.
/// Protege contra perda por exclusão (deve ir para a lixeira, recuperável) e contra
/// embaralhamento da ordem de exibição.
final class TrashAndReorderTests: CadernoTestCase {

    // MARK: - 5. deleteToTrashAndRestore

    /// Apagar remove de pageOrder mas mantém recuperável; `restorePage` traz de volta.
    func test_deleteToTrashAndRestore() throws {
        let store = try makeStore()
        let p0 = try XCTUnwrap(try store.pages().first?.id)
        let p1 = try store.addPage(template: "ruled").id
        let p2 = try store.addPage(template: "grid").id

        // Dá um traço à página do meio para checar que a restauração traz o conteúdo junto.
        let mark = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try store.writeDrawing(mark, pageID: p1)

        // Apaga a do meio.
        try store.deletePage(id: p1)

        var order = try store.loadManifest().pageOrder
        XCTAssertEqual(order, [p0, p2],
                       "deletePage deve remover o id de pageOrder, mantendo os demais na ordem.")
        XCTAssertEqual(ids(try store.pages()), [p0, p2],
                       "pages() não deve listar a página apagada.")

        // Não deve ter sumido de verdade: continua recuperável.
        try store.restorePage(id: p1)

        order = try store.loadManifest().pageOrder
        XCTAssertEqual(order, [p0, p1, p2],
                       "restorePage deve trazer a página de volta à sua posição original (índice 1).")
        XCTAssertEqual(ids(try store.pages()), [p0, p1, p2],
                       "pages() deve voltar a listar a página restaurada na ordem correta.")

        // O conteúdo (traço + metadados) tem de voltar intacto.
        XCTAssertEqual(try store.readDrawing(pageID: p1), mark,
                       "O traço da página restaurada deve voltar byte-a-byte, sem perda.")
        XCTAssertEqual(try store.pageMeta(id: p1).template, "ruled",
                       "Os metadados da página restaurada devem ser preservados.")

        // E deve sobreviver à reabertura.
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        XCTAssertEqual(reopened.pageOrderIDsOrEmpty(), [p0, p1, p2],
                       "A restauração deve estar persistida (visível após reabrir).")
    }

    // MARK: - 6. reorderPages

    /// `movePage` reordena pageOrder corretamente — para o início, para o meio e para o fim.
    /// Semântica testada: remove o id e reinsere na posição `toIndex` do array resultante.
    func test_reorderPages() throws {
        let store = try makeStore()
        let p0 = try XCTUnwrap(try store.pages().first?.id)
        let p1 = try store.addPage(template: "blank").id
        let p2 = try store.addPage(template: "blank").id
        let p3 = try store.addPage(template: "blank").id

        XCTAssertEqual(try store.loadManifest().pageOrder, [p0, p1, p2, p3],
                       "Pré-condição: ordem inicial [p0, p1, p2, p3].")

        // (a) Mover o último para o INÍCIO.
        try store.movePage(id: p3, toIndex: 0)
        XCTAssertEqual(try store.loadManifest().pageOrder, [p3, p0, p1, p2],
                       "Mover p3 para o índice 0 deve colocá-lo no início.")

        // (b) Mover para o MEIO.
        try store.movePage(id: p3, toIndex: 2)
        XCTAssertEqual(try store.loadManifest().pageOrder, [p0, p1, p3, p2],
                       "Mover p3 para o índice 2 deve colocá-lo no meio.")

        // (c) Mover para o FIM.
        try store.movePage(id: p0, toIndex: 3)
        XCTAssertEqual(try store.loadManifest().pageOrder, [p1, p3, p2, p0],
                       "Mover p0 para o último índice deve colocá-lo no fim.")

        // pages() deve seguir a mesma ordem de pageOrder.
        XCTAssertEqual(ids(try store.pages()), [p1, p3, p2, p0],
                       "pages() deve refletir a ordem final de pageOrder.")

        // E a nova ordem deve estar persistida.
        let reopened = try NotebookStore.open(packageURL: store.packageURL)
        XCTAssertEqual(try reopened.loadManifest().pageOrder, [p1, p3, p2, p0],
                       "A reordenação deve sobreviver à reabertura.")
    }
}

private extension NotebookStore {
    /// Helper defensivo para asserts de leitura (evita `try` aninhado no XCTAssert).
    func pageOrderIDsOrEmpty() -> [String] {
        (try? loadManifest().pageOrder) ?? []
    }
}
