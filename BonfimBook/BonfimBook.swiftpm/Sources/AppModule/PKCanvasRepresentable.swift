import SwiftUI
import PencilKit
import CadernoCore

/// Ponte SwiftUI ↔ PencilKit para uma página do caderno.
///
/// Regra de ouro (CONTRACT.md): o salvamento LOCAL (camada 1) sempre acontece antes do
/// espelhamento de backup (camada 2), e a escrita em disco ocorre FORA da main thread,
/// com debounce ~0,4s. Nenhuma perda silenciosa.
struct PKCanvasRepresentable: UIViewRepresentable {
    let store: NotebookStore
    let backup: BackupManager
    let pageID: String
    @Binding var drawingPolicy: PKCanvasViewDrawingPolicy

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, backup: backup, pageID: pageID)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = drawingPolicy
        canvas.alwaysBounceVertical = false
        canvas.backgroundColor = .systemBackground

        // Carga inicial: bytes opacos → PKDrawing. `nil` = página ainda sem traço.
        // `try?` sobre uma função que devolve `Data?` já entrega `Data?` (Swift achata o
        // opcional), então UM `if let` basta — um segundo desempacotamento não compila.
        if let data = try? store.readDrawing(pageID: pageID),
           let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }

        // Tool picker flutuante padrão do PencilKit.
        let toolPicker = PKToolPicker()
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.toolPicker = toolPicker
        DispatchQueue.main.async {
            canvas.becomeFirstResponder()
        }

        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawingPolicy != drawingPolicy {
            canvas.drawingPolicy = drawingPolicy
        }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        // Garante que um traço recém-feito não se perca ao trocar de página/tela:
        // grava de forma síncrona o estado pendente antes de descartar a view.
        coordinator.flushPendingSave(from: canvas)
        coordinator.toolPicker?.setVisible(false, forFirstResponder: canvas)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let store: NotebookStore
        private let backup: BackupManager
        private let pageID: String
        var toolPicker: PKToolPicker?

        /// Fila SERIAL de background: as gravações não competem com a main thread
        /// e nunca rodam concorrentes entre si.
        private let saveQueue = DispatchQueue(label: "br.pessoal.caderno.save", qos: .utility)
        private var pendingWork: DispatchWorkItem?

        init(store: NotebookStore, backup: BackupManager, pageID: String) {
            self.store = store
            self.backup = backup
            self.pageID = pageID
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Lê o desenho na main thread (onde o delegate roda) e agenda a gravação
            // pesada para a fila de background com debounce.
            let data = canvasView.drawing.dataRepresentation()
            scheduleSave(data)
        }

        private func scheduleSave(_ data: Data) {
            pendingWork?.cancel()
            let work = DispatchWorkItem { [store, backup, pageID] in
                do {
                    // Camada 1 — salvamento local SEMPRE primeiro.
                    try store.writeDrawing(data, pageID: pageID)
                    // Camada 2 — só espelha se o local deu certo. `mirror` é @MainActor.
                    let package = store.packageURL
                    DispatchQueue.main.async {
                        backup.mirror(package: package)
                    }
                } catch {
                    // NOTA: falha de salvamento LOCAL. O contrato exige "nenhuma perda
                    // silenciosa"; como AppState/BackupManager não expõem canal para erro
                    // de camada 1, registramos alto e NÃO chamamos mirror (para o backup
                    // não sinalizar "salvo" indevidamente).
                    NSLog("[Caderno] Falha ao salvar página \(pageID) localmente: \(error)")
                    assertionFailure("Falha ao salvar desenho localmente: \(error)")
                }
            }
            pendingWork = work
            saveQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        /// Grava de forma síncrona o desenho atual, cancelando qualquer debounce pendente.
        /// Usado no dismantle para não perder o último traço.
        func flushPendingSave(from canvasView: PKCanvasView) {
            pendingWork?.cancel()
            pendingWork = nil
            let data = canvasView.drawing.dataRepresentation()
            // Ligamos a constantes locais para as closures capturarem os LOCAIS (e não
            // `self`), evitando o erro "requires explicit use of 'self'". Mesmo padrão
            // do capture list usado em `scheduleSave`.
            let store = self.store
            let backup = self.backup
            let pageID = self.pageID
            saveQueue.sync {
                do {
                    try store.writeDrawing(data, pageID: pageID)
                    let package = store.packageURL
                    DispatchQueue.main.async {
                        backup.mirror(package: package)
                    }
                } catch {
                    NSLog("[Caderno] Falha ao salvar página \(pageID) no flush: \(error)")
                }
            }
        }
    }
}
