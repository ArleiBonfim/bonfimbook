import XCTest
import Foundation
@testable import CadernoCore

// MARK: - Base de teste

/// Base para todos os testes do CadernoCore.
///
/// Garante o requisito do contrato: cada teste cria seu pacote num diretório
/// temporário ÚNICO e limpa tudo no tearDown, para que nenhum teste vaze estado
/// em disco para outro (os testes tocam o filesystem de verdade).
class CadernoTestCase: XCTestCase {

    /// Diretório-pai único desta execução de teste. Todo `.caderno` criado aqui dentro.
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fábricas

    /// Cria um store novo dentro do tempDir desta execução.
    func makeStore(title: String = "Teste") throws -> NotebookStore {
        try NotebookStore.create(at: tempDir, title: title)
    }

    // MARK: - Caminhos internos do pacote (derivados do layout do CONTRACT)

    func pagesDir(_ store: NotebookStore) -> URL {
        store.packageURL.appendingPathComponent("pages", isDirectory: true)
    }

    func pageJSONURL(_ store: NotebookStore, id: String) -> URL {
        pagesDir(store).appendingPathComponent("\(id).json")
    }

    func pageDrawingURL(_ store: NotebookStore, id: String) -> URL {
        pagesDir(store).appendingPathComponent("\(id).drawing")
    }

    func manifestURL(_ store: NotebookStore) -> URL {
        store.packageURL.appendingPathComponent("manifest.json")
    }

    // MARK: - Utilidades

    func ids(_ pages: [PageMeta]) -> [String] { pages.map(\.id) }
}

// MARK: - Asserts de erro tipado

extension XCTestCase {

    /// Assert que `expression` lança `CadernoError.integrityFailed(_)`, ignorando a
    /// mensagem associada (que é detalhe de implementação).
    func assertThrowsIntegrityFailed(_ expression: () throws -> Void,
                                     _ message: String = "",
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        do {
            try expression()
            XCTFail("Esperava lançar CadernoError.integrityFailed, mas não lançou. \(message)",
                    file: file, line: line)
        } catch let error as CadernoError {
            if case .integrityFailed = error {
                // ok
            } else {
                XCTFail("Esperava .integrityFailed, mas lançou \(error). \(message)",
                        file: file, line: line)
            }
        } catch {
            XCTFail("Esperava CadernoError.integrityFailed, mas lançou \(error). \(message)",
                    file: file, line: line)
        }
    }

    /// Assert que `expression` NÃO lança.
    func assertNoThrow_(_ expression: () throws -> Void,
                        _ message: String = "",
                        file: StaticString = #filePath,
                        line: UInt = #line) {
        do {
            try expression()
        } catch {
            XCTFail("Não esperava erro, mas lançou \(error). \(message)",
                    file: file, line: line)
        }
    }
}
