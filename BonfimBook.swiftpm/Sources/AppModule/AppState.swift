import Foundation
import CadernoCore

/// Dono do `NotebookStore` atual e do id da página aberta.
/// Assinatura fixada no CONTRACT.md — não alterar campos públicos.
@MainActor
final class AppState: ObservableObject {
    @Published var store: NotebookStore
    @Published var currentPageID: String
    let backup: BackupManager        // injetado

    init(store: NotebookStore, currentPageID: String, backup: BackupManager) {
        self.store = store
        self.currentPageID = currentPageID
        self.backup = backup
    }
}
