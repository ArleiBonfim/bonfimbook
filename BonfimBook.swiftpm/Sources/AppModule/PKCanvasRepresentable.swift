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
    /// Controlador de Undo/Redo (e ancoragem do zoom). Injetado pelo integrador.
    let controller: CanvasController

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, backup: backup, pageID: pageID, controller: controller)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = drawingPolicy
        canvas.alwaysBounceVertical = false
        // Fundo transparente para o PaperBackgroundView (o papel) aparecer atrás.
        // Nunca `.systemBackground` — ficaria preto no dark mode (ver CONTRACT gotchas).
        canvas.backgroundColor = .clear
        canvas.isOpaque = false

        // Habilita pinça-para-zoom do desenho. `PKCanvasView` é subclasse de
        // `UIScrollView`, então basta configurar a escala mínima/máxima e o "bounce".
        canvas.minimumZoomScale = 1.0
        canvas.maximumZoomScale = 4.0
        canvas.bouncesZoom = true

        // Carga inicial: bytes opacos → PKDrawing. `nil` = página ainda sem traço.
        // `try?` sobre uma função que devolve `Data?` já entrega `Data?` (Swift achata o
        // opcional), então UM `if let` basta — um segundo desempacotamento não compila.
        if let data = try? store.readDrawing(pageID: pageID),
           let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }

        // Paleta da Apple: criada sempre, mas quem decide se aparece é o controlador
        // (`useSystemPicker`). Por padrão fica ESCONDIDA e a nossa barra fina assume.
        let toolPicker = PKToolPicker()
        context.coordinator.toolPicker = toolPicker   // dono forte

        // Liga o controlador ao canvas e à paleta, decide a visibilidade inicial (barra fina
        // ou paleta), aplica a caneta atual e sincroniza os botões — tudo na main thread,
        // pois o controlador é `ObservableObject` observado pela UI.
        let controller = self.controller
        DispatchQueue.main.async {
            controller.canvas = canvas
            controller.toolPicker = toolPicker
            controller.syncPickerVisibility()   // mostra paleta OU aplica a caneta da barra
            controller.refresh()
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
        private let controller: CanvasController
        var toolPicker: PKToolPicker?

        /// Fila SERIAL de background: as gravações não competem com a main thread
        /// e nunca rodam concorrentes entre si.
        private let saveQueue = DispatchQueue(label: "br.pessoal.caderno.save", qos: .utility)
        private var pendingWork: DispatchWorkItem?

        init(store: NotebookStore, backup: BackupManager, pageID: String, controller: CanvasController) {
            self.store = store
            self.backup = backup
            self.pageID = pageID
            self.controller = controller
        }

        // MARK: - Zoom/rolagem → espelhar nas camadas de trás
        //
        // `PKCanvasView` é um `UIScrollView`; ao dar pinça ou rolar com dois dedos, ele
        // amplia/desloca o TRAÇO (que continua nítido, pois o PencilKit re-renderiza vetores).
        // Estes dois callbacks publicam a mesma escala/deslocamento no controlador para o
        // papel e as imagens acompanharem, dando a sensação de zoom da PÁGINA inteira.

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            publishZoom(scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            publishZoom(scrollView)
        }

        /// Copia escala e deslocamento atuais do canvas para o controlador. Roda na main
        /// (delegate de UI), então atualiza os `@Published` direto.
        private func publishZoom(_ scrollView: UIScrollView) {
            controller.zoomScale = scrollView.zoomScale
            controller.contentOffset = scrollView.contentOffset
        }

        // MARK: - Modo formas: ao levantar a caneta, tenta virar forma perfeita
        //
        // `canvasViewDidEndUsingTool` dispara quando o usuário termina um traço. Se o modo
        // formas estiver ligado e a ferramenta for de tinta, analisamos o ÚLTIMO traço e, se
        // for uma linha/retângulo/círculo, trocamos pela forma perfeita — registrando o
        // desfazer para poder reverter. Roda em `async` para garantir que o traço já foi
        // efetivado no `drawing`.
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard controller.shapeMode, canvasView.tool is PKInkingTool else { return }
            DispatchQueue.main.async { [weak self] in
                self?.snapLastStroke(in: canvasView)
            }
        }

        private func snapLastStroke(in canvasView: PKCanvasView) {
            guard let last = canvasView.drawing.strokes.last,
                  let snapped = ShapeSnapper.snap(last) else { return }

            let oldDrawing = canvasView.drawing
            var strokes = oldDrawing.strokes
            strokes.removeLast()
            strokes.append(snapped)
            canvasView.drawing = PKDrawing(strokes: strokes)

            // Trocar `drawing` na mão NÃO dispara o salvamento automático — avisamos o delegate.
            canvasViewDrawingDidChange(canvasView)

            // Desfazer volta ao traço original à mão.
            canvasView.undoManager?.registerUndo(withTarget: canvasView) { c in
                c.drawing = oldDrawing
                c.delegate?.canvasViewDrawingDidChange?(c)
            }
            canvasView.undoManager?.setActionName("Formatar forma")
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Lê o desenho na main thread (onde o delegate roda) e agenda a gravação
            // pesada para a fila de background com debounce.
            let data = canvasView.drawing.dataRepresentation()
            scheduleSave(data)

            // Depois de agendar o salvamento (sem mexer nele), reavalia desfazer/refazer.
            // Capturamos `self` fraco de forma EXPLÍCITA na lista de captura: referenciar
            // um `self` capturado por `var` dentro de closure concorrente não compila.
            DispatchQueue.main.async { [weak self] in
                self?.controller.refresh()
            }
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
