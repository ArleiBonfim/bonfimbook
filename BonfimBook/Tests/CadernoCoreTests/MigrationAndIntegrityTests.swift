import XCTest
import Foundation
@testable import CadernoCore

/// Migração de schema e verificação de integridade.
/// Protege contra migração destrutiva (v1 deve ser identidade) e contra o caderno
/// "achar que está são" quando um arquivo de página some do disco.
final class MigrationAndIntegrityTests: CadernoTestCase {

    // MARK: - 7. migrationIdentity

    /// `Migrator.migrate` de um manifest v1 deve devolver um manifest equivalente,
    /// preservando o schemaVersion (na v1 a migração é identidade).
    func test_migrationIdentity() throws {
        // Data fixa em segundos inteiros: iso8601 não guarda fração, então isso
        // mantém o teste estável independentemente do encoder.
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Manifest(
            schemaVersion: 1,
            notebookID: UUID().uuidString,
            title: "Original v1",
            createdAt: fixedDate,
            updatedAt: fixedDate,
            pageOrder: ["a", "b", "c"]
        )

        let migrated = try Migrator.migrate(original)

        XCTAssertEqual(migrated.schemaVersion, 1,
                       "Na v1 a migração deve preservar schemaVersion == 1.")
        XCTAssertEqual(migrated.schemaVersion, CadernoSchema.current,
                       "O schema migrado deve coincidir com o schema atual suportado.")
        XCTAssertEqual(migrated, original,
                       "Migração de v1 deve ser identidade: nenhum campo pode ser alterado ou perdido.")

        // Idempotência: migrar de novo não muda nada.
        XCTAssertEqual(try Migrator.migrate(migrated), original,
                       "Migrar um manifest já atual deve ser idempotente.")
    }

    // MARK: - 8. integrityDetectsMissingFile

    /// Remover manualmente um pages/<id>.json deve fazer `verifyIntegrity()` lançar
    /// `integrityFailed` — o caderno não pode fingir estar íntegro.
    func test_integrityDetectsMissingFile() throws {
        let store = try makeStore()
        _ = try store.addPage(template: "ruled")
        let victim = try store.addPage(template: "grid").id

        // Baseline: um caderno íntegro NÃO lança.
        assertNoThrow_({ try store.verifyIntegrity() },
                       "Um caderno recém-criado e consistente não deve falhar na verificação de integridade.")

        // Corrompe: apaga o metadado de uma página que ainda está em pageOrder.
        let victimJSON = pageJSONURL(store, id: victim)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victimJSON.path),
                      "Pré-condição: o arquivo pages/\(victim).json deve existir antes de removê-lo.")
        try FileManager.default.removeItem(at: victimJSON)

        // Agora a verificação tem de acusar.
        assertThrowsIntegrityFailed({ try store.verifyIntegrity() },
                                    "Faltando pages/\(victim).json, verifyIntegrity() deve lançar .integrityFailed.")
    }
}
