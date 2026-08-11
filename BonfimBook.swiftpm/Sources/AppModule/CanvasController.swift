import SwiftUI
import PencilKit

/// Controlador leve de Undo/Redo do canvas de desenho.
///
/// Faz a ponte entre a UI SwiftUI (que precisa saber se os botões desfazer/refazer
/// estão habilitados) e o `PKCanvasView`, que é um `UIScrollView` do UIKit e traz seu
/// próprio `UndoManager`. Não guardamos histórico próprio: apenas delegamos ao
/// `UndoManager` nativo do canvas — assim o comportamento acompanha exatamente o que o
/// PencilKit registra (traços, apagador, etc.).
///
/// O `canvas` é uma referência FRACA (`weak`): quem é dono da view é o ciclo de vida do
/// `UIViewRepresentable`. Se o canvas for descartado, o controlador simplesmente para de
/// ter efeito, sem manter a view viva nem causar retain cycle.
final class CanvasController: ObservableObject {
    /// Referência fraca ao canvas ativo. Atribuída no `makeUIView` (na main thread).
    weak var canvas: PKCanvasView?

    /// Espelham o estado do `UndoManager` para a UI. Publicados para as views observarem.
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false

    /// Desfaz o último passo registrado no canvas e reavalia o estado dos botões.
    func undo() {
        canvas?.undoManager?.undo()
        refresh()
    }

    /// Refaz o passo desfeito mais recente e reavalia o estado dos botões.
    func redo() {
        canvas?.undoManager?.redo()
        refresh()
    }

    /// "Melhora de traço": suaviza os tremidos da escrita da página atual, mantendo pressão,
    /// cor e espessura. É OPT-IN (só roda quando o usuário toca no botão) e REVERSÍVEL (fica
    /// registrado no desfazer). Programaticamente trocar `canvas.drawing` NÃO dispara o
    /// salvamento automático, então avisamos o delegate na mão para persistir.
    func smoothStrokes() {
        guard let canvas = canvas else { return }
        let old = canvas.drawing
        guard !old.strokes.isEmpty else { return }

        let new = Self.smoothed(old)
        canvas.drawing = new
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)   // dispara salvar + atualizar botões

        // Registra o desfazer: volta ao traço original e persiste de novo.
        canvas.undoManager?.registerUndo(withTarget: canvas) { c in
            c.drawing = old
            c.delegate?.canvasViewDrawingDidChange?(c)
        }
        canvas.undoManager?.setActionName("Melhorar traço")
        refresh()
    }

    /// Suaviza cada traço por média móvel (janela 3) das posições dos pontos de controle,
    /// preservando os demais atributos (tempo, tamanho, opacidade, força, inclinação).
    private static func smoothed(_ drawing: PKDrawing) -> PKDrawing {
        var newStrokes: [PKStroke] = []
        for stroke in drawing.strokes {
            let pts = Array(stroke.path)
            // Traços muito curtos não têm o que suavizar sem distorcer.
            guard pts.count >= 3 else {
                newStrokes.append(stroke)
                continue
            }
            var smoothedPts: [PKStrokePoint] = []
            smoothedPts.reserveCapacity(pts.count)
            for i in pts.indices {
                let prev = pts[max(0, i - 1)]
                let cur = pts[i]
                let next = pts[min(pts.count - 1, i + 1)]
                let avg = CGPoint(x: (prev.location.x + cur.location.x + next.location.x) / 3,
                                  y: (prev.location.y + cur.location.y + next.location.y) / 3)
                smoothedPts.append(
                    PKStrokePoint(location: avg,
                                  timeOffset: cur.timeOffset,
                                  size: cur.size,
                                  opacity: cur.opacity,
                                  force: cur.force,
                                  azimuth: cur.azimuth,
                                  altitude: cur.altitude)
                )
            }
            let newPath = PKStrokePath(controlPoints: smoothedPts, creationDate: stroke.path.creationDate)
            let newStroke = PKStroke(ink: stroke.ink, path: newPath, transform: stroke.transform, mask: stroke.mask)
            newStrokes.append(newStroke)
        }
        return PKDrawing(strokes: newStrokes)
    }

    /// Sincroniza `canUndo`/`canRedo` com o `UndoManager` do canvas.
    ///
    /// Como mexe em `@Published` (que dispara atualização de UI), precisa rodar na main
    /// thread. Se já estivermos nela, atualiza direto; senão, reagenda. Assim o método é
    /// seguro de chamar de qualquer contexto.
    func refresh() {
        if Thread.isMainThread {
            let manager = canvas?.undoManager
            canUndo = manager?.canUndo ?? false
            canRedo = manager?.canRedo ?? false
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
        }
    }
}
