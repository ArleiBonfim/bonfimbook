import Foundation
import CadernoCore

/// Estado global mínimo do app (Fase 1+). O caderno aberto NÃO mora mais aqui —
/// a navegação (NavigationStack + `LibraryView`/`NotebookView`) cuida disso.
/// Guarda apenas o `BackupManager` e o diretório da biblioteca.
@MainActor
final class AppState: ObservableObject {
    /// Diretório onde vivem os pacotes `*.caderno` (normalmente `.documentDirectory`).
    let libraryDirectory: URL
    /// Camada de backup global (também injetada como `@EnvironmentObject` no `CadernoApp`).
    let backup: BackupManager

    init(libraryDirectory: URL, backup: BackupManager) {
        self.libraryDirectory = libraryDirectory
        self.backup = backup
    }
}
