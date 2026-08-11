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
