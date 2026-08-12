import SwiftUI
import UIKit
import PencilKit

/// Tipos de "caneta" oferecidos pela nossa barra fina (mesmos traços do PencilKit).
enum PenKind: String, CaseIterable {
    case pen         // caneta esferográfica
    case marker      // marca-texto (destaque)
    case pencil      // lápis
    case fountainPen // caneta tinteiro (varia com a pressão)
    case monoline    // monolinha (espessura constante)
    case crayon      // giz de cera
    case watercolor  // aquarela
    case eraser      // borracha (apaga o traço inteiro — "apagar rabiscando")
    case lasso       // laço (selecionar/mover traços)
}

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

    // MARK: - Barra de canetas (nossa, discreta) x Paleta da Apple

    /// Referência FRACA à paleta flutuante da Apple. O dono forte é o Coordinator do
    /// `PKCanvasRepresentable`; aqui só a usamos para mostrar/esconder.
    weak var toolPicker: PKToolPicker?

    /// `true` = usar a paleta completa da Apple (flutuante). `false` (padrão) = usar a
    /// nossa barra fina no topo, mais discreta. As duas controlam o MESMO canvas.
    @Published var useSystemPicker: Bool = false

    /// Estado da nossa barra fina (qual caneta, cor e espessura estão ativas).
    @Published var toolKind: PenKind = .pen
    @Published var inkColor: Color = .black
    @Published var lineWidth: CGFloat = 5

    /// "Modo formas": quando ligado, ao levantar a caneta o traço desenhado é analisado e,
    /// se parecer uma linha/retângulo/círculo, é trocado pela forma perfeita (REVERSÍVEL no
    /// desfazer). Opt-in — desligado não muda nada. A troca é feita no Coordinator.
    @Published var shapeMode: Bool = false

    // MARK: - Zoom da PÁGINA INTEIRA (papel + imagens acompanham o traço)

    /// Espelham o zoom/rolagem do canvas para as camadas de trás (papel e imagens) seguirem
    /// junto. Quem escreve nestes é o Coordinator do `PKCanvasRepresentable` (via delegate de
    /// scroll); a UI só LÊ para aplicar o mesmo `scaleEffect`/`offset` no papel e nas imagens.
    @Published var zoomScale: CGFloat = 1
    @Published var contentOffset: CGPoint = .zero

    /// Volta o zoom ao normal (1×, sem deslocamento). Usado ao entrar nos modos imagem/estudo,
    /// onde o zoom do canvas não está ativo e manteria as camadas desalinhadas.
    func resetZoom() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.resetZoom() }
            return
        }
        zoomScale = 1
        contentOffset = .zero
        canvas?.setZoomScale(1, animated: false)
        canvas?.setContentOffset(.zero, animated: false)
    }

    /// Aplica no canvas a caneta/cor/espessura atuais da barra fina. É o coração da barra:
    /// toda vez que o usuário toca numa caneta, cor ou espessura, chamamos isto. Trocar o
    /// `tool` programaticamente só "pega" quando a paleta da Apple NÃO está observando o
    /// canvas — por isso `syncPickerVisibility()` remove o observador ao usar a barra fina.
    func applyTool() {
        guard let canvas = canvas else { return }
        let color = UIColor(inkColor)
        switch toolKind {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
        case .marker:
            // Marca-texto é mais largo e translúcido por natureza; engrossa a ponta.
            canvas.tool = PKInkingTool(.marker, color: color, width: max(lineWidth * 3, 14))
        case .pencil:
            canvas.tool = PKInkingTool(.pencil, color: color, width: lineWidth)
        case .fountainPen:
            // Canetas novas exigem iPadOS 17; em versões antigas caem num equivalente próximo.
            if #available(iOS 17.0, *) {
                canvas.tool = PKInkingTool(.fountainPen, color: color, width: lineWidth)
            } else {
                canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
            }
        case .monoline:
            if #available(iOS 17.0, *) {
                canvas.tool = PKInkingTool(.monoline, color: color, width: lineWidth)
            } else {
                canvas.tool = PKInkingTool(.pen, color: color, width: lineWidth)
            }
        case .crayon:
            if #available(iOS 17.0, *) {
                canvas.tool = PKInkingTool(.crayon, color: color, width: max(lineWidth, 6))
            } else {
                canvas.tool = PKInkingTool(.pencil, color: color, width: max(lineWidth, 6))
            }
        case .watercolor:
            if #available(iOS 17.0, *) {
                canvas.tool = PKInkingTool(.watercolor, color: color, width: max(lineWidth * 2, 12))
            } else {
                canvas.tool = PKInkingTool(.marker, color: color, width: max(lineWidth * 2, 12))
            }
        case .eraser:
            // Borracha de OBJETO: passa por cima e o traço inteiro some (apagar rabiscando).
            canvas.tool = PKEraserTool(.vector)
        case .lasso:
            canvas.tool = PKLassoTool()
        }
    }

    /// Seleciona uma caneta de tinta (caneta/marca-texto/lápis) e aplica na hora.
    func selectInk(_ kind: PenKind) {
        toolKind = kind
        applyTool()
    }

    /// Define a cor atual. Se estava na borracha/laço, volta para a caneta (faz mais sentido
    /// escolher cor querendo escrever). Aplica na hora.
    func selectColor(_ color: Color) {
        inkColor = color
        if toolKind == .eraser || toolKind == .lasso { toolKind = .pen }
        applyTool()
    }

    /// Define a espessura atual e aplica na hora.
    func selectWidth(_ width: CGFloat) {
        lineWidth = width
        if toolKind == .eraser || toolKind == .lasso { toolKind = .pen }
        applyTool()
    }

    /// Mostra a paleta da Apple OU a nossa barra fina, conforme `useSystemPicker`.
    ///
    /// Regra crucial: quando a paleta da Apple está VISÍVEL e OBSERVANDO o canvas, ela manda
    /// no `tool`. Para a nossa barra fina funcionar, precisamos remover esse observador e
    /// reaplicar a nossa caneta. Ao voltar para a paleta, re-adicionamos o observador.
    func syncPickerVisibility() {
        guard let canvas = canvas, let picker = toolPicker else { return }
        if useSystemPicker {
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
        } else {
            picker.setVisible(false, forFirstResponder: canvas)
            picker.removeObserver(canvas)
            applyTool()
        }
        canvas.becomeFirstResponder()
    }

    // MARK: - NOSSO laço (seleção de escrita) — resize/cor/mover/duplicar/apagar
    //
    // O PencilKit NÃO expõe a seleção do laço nativo, então construímos o nosso: o usuário
    // cerca a escrita com um laço, achamos os traços dentro da área e aplicamos transformações
    // reconstruindo o `PKDrawing`. Tudo reversível pelo desfazer.

    /// Modo laço ligado (a UI mostra a camada de seleção por cima do canvas).
    @Published var selectionActive: Bool = false
    /// Retângulo que envolve a seleção atual (coordenadas do canvas), ou nil se nada selecionado.
    @Published var selectionBounds: CGRect? = nil
    /// Índices (na lista de traços do desenho) atualmente selecionados.
    private var selectedIndices: [Int] = []
    /// Snapshot para registrar UM desfazer durante um arraste contínuo (mover).
    private var transformSnapshot: PKDrawing?

    func beginSelectMode() { selectionActive = true; clearSelection() }
    func endSelectMode() { selectionActive = false; clearSelection() }
    func clearSelection() { selectedIndices = []; selectionBounds = nil }

    var hasSelection: Bool { !selectedIndices.isEmpty }

    /// Seleciona os traços cujos pontos caem, em maioria, DENTRO do laço desenhado.
    func selectStrokes(inPolygon polygon: [CGPoint]) {
        guard let canvas = canvas, polygon.count >= 3 else { clearSelection(); return }
        let strokes = canvas.drawing.strokes
        var indices: [Int] = []
        for (i, stroke) in strokes.enumerated() {
            let pts = Array(stroke.path).map { $0.location.applying(stroke.transform) }
            guard !pts.isEmpty else { continue }
            var inside = 0
            for p in pts where Self.pointInPolygon(p, polygon) { inside += 1 }
            if Double(inside) / Double(pts.count) >= 0.5 { indices.append(i) }
        }
        selectedIndices = indices
        recomputeBounds()
    }

    /// Aumenta/diminui a seleção pelo fator (ex.: 1.2 = +20%), em torno do centro.
    func scaleSelection(_ factor: CGFloat) {
        guard let b = selectionBounds else { return }
        let c = CGPoint(x: b.midX, y: b.midY)
        let m = CGAffineTransform(translationX: c.x, y: c.y)
            .scaledBy(x: factor, y: factor)
            .translatedBy(x: -c.x, y: -c.y)
        rebuildSelected(registerUndo: true) { s in
            PKStroke(ink: s.ink, path: s.path, transform: s.transform.concatenating(m), mask: s.mask)
        }
    }

    /// Troca a cor de toda a escrita selecionada.
    func colorSelection(_ color: UIColor) {
        rebuildSelected(registerUndo: true) { s in
            PKStroke(ink: PKInk(s.ink.inkType, color: color), path: s.path,
                     transform: s.transform, mask: s.mask)
        }
    }

    /// Início/fim de um arraste contínuo de MOVER (um só desfazer para todo o gesto).
    func beginTransform() { transformSnapshot = canvas?.drawing }
    func endTransform() {
        if let snap = transformSnapshot { registerUndo(snap) }
        transformSnapshot = nil
        recomputeBounds()
    }

    /// Move a seleção por um incremento (chamado a cada quadro do arraste; sem desfazer aqui).
    func translateSelectionLive(dx: CGFloat, dy: CGFloat) {
        let m = CGAffineTransform(translationX: dx, y: dy)
        rebuildSelected(registerUndo: false) { s in
            PKStroke(ink: s.ink, path: s.path, transform: s.transform.concatenating(m), mask: s.mask)
        }
    }

    /// Apaga a escrita selecionada.
    func deleteSelection() {
        guard let canvas = canvas, !selectedIndices.isEmpty else { return }
        let old = canvas.drawing
        let set = Set(selectedIndices)
        let strokes = old.strokes.enumerated().filter { !set.contains($0.offset) }.map { $0.element }
        canvas.drawing = PKDrawing(strokes: strokes)
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
        registerUndo(old)
        clearSelection()
    }

    /// Duplica a escrita selecionada (deslocada) e passa a selecionar as cópias.
    func duplicateSelection() {
        guard let canvas = canvas, !selectedIndices.isEmpty else { return }
        let old = canvas.drawing
        var strokes = old.strokes
        let m = CGAffineTransform(translationX: 26, y: 26)
        let start = strokes.count
        for i in selectedIndices where old.strokes.indices.contains(i) {
            let s = old.strokes[i]
            strokes.append(PKStroke(ink: s.ink, path: s.path,
                                    transform: s.transform.concatenating(m), mask: s.mask))
        }
        canvas.drawing = PKDrawing(strokes: strokes)
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
        registerUndo(old)
        selectedIndices = Array(start..<strokes.count)
        recomputeBounds()
    }

    // MARK: Auxiliares do laço

    /// Reconstrói o desenho aplicando `transform` só aos traços selecionados.
    private func rebuildSelected(registerUndo doUndo: Bool, _ transform: (PKStroke) -> PKStroke) {
        guard let canvas = canvas, !selectedIndices.isEmpty else { return }
        let old = canvas.drawing
        var strokes = old.strokes
        for i in selectedIndices where strokes.indices.contains(i) {
            strokes[i] = transform(strokes[i])
        }
        canvas.drawing = PKDrawing(strokes: strokes)
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
        if doUndo { registerUndo(old) }
        recomputeBounds()
    }

    /// Recalcula o retângulo que envolve a seleção (união dos limites dos traços).
    private func recomputeBounds() {
        guard let canvas = canvas, !selectedIndices.isEmpty else { selectionBounds = nil; return }
        let strokes = canvas.drawing.strokes
        var rect: CGRect?
        for i in selectedIndices where strokes.indices.contains(i) {
            let b = strokes[i].renderBounds
            rect = (rect == nil) ? b : rect!.union(b)
        }
        selectionBounds = rect
    }

    /// Registra um desfazer que volta o desenho a `old`.
    private func registerUndo(_ old: PKDrawing) {
        guard let canvas = canvas else { return }
        canvas.undoManager?.registerUndo(withTarget: canvas) { c in
            c.drawing = old
            c.delegate?.canvasViewDrawingDidChange?(c)
        }
        canvas.undoManager?.setActionName("Editar seleção")
        refresh()
    }

    /// Teste ponto-dentro-do-polígono (ray casting), para saber o que o laço cercou.
    private static func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

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

    /// Quantas vezes aplicamos a média móvel. Mais passagens = traço visivelmente mais liso.
    private static let smoothingPasses = 5

    /// Suaviza cada traço por VÁRIAS passagens de média móvel (janela 5) sobre as posições dos
    /// pontos de controle, preservando os demais atributos (tempo, tamanho, opacidade, força,
    /// inclinação). Uma passagem só quase não se nota; repetir deixa a diferença clara.
    private static func smoothed(_ drawing: PKDrawing) -> PKDrawing {
        var newStrokes: [PKStroke] = []
        for stroke in drawing.strokes {
            let pts = Array(stroke.path)
            // Traços muito curtos não têm o que suavizar sem distorcer.
            guard pts.count >= 4 else {
                newStrokes.append(stroke)
                continue
            }

            // Trabalha só nas posições; os atributos ficam colados ao índice original.
            var locations = pts.map { $0.location }
            for _ in 0..<smoothingPasses {
                locations = averagePass(locations)
            }

            var smoothedPts: [PKStrokePoint] = []
            smoothedPts.reserveCapacity(pts.count)
            for i in pts.indices {
                let cur = pts[i]
                smoothedPts.append(
                    PKStrokePoint(location: locations[i],
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

    /// Uma passagem de média móvel (janela 5) mantendo as pontas fixas (para o traço não
    /// "encolher" nas extremidades).
    private static func averagePass(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 4 else { return points }
        var out = points
        for i in 1..<(points.count - 1) {
            let a = points[max(0, i - 2)]
            let b = points[i - 1]
            let c = points[i]
            let d = points[i + 1]
            let e = points[min(points.count - 1, i + 2)]
            out[i] = CGPoint(x: (a.x + b.x + c.x + d.x + e.x) / 5,
                             y: (a.y + b.y + c.y + d.y + e.y) / 5)
        }
        return out
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
