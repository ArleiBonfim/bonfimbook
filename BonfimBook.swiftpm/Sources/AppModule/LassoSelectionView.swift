import SwiftUI

/// Camada do NOSSO laço, desenhada por cima do canvas quando o modo laço está ligado.
///
/// - Arraste em qualquer lugar: desenha um laço; ao soltar, seleciona a escrita cercada.
/// - Com algo selecionado: arraste DENTRO da caixa azul para mover a escrita.
/// As demais ações (aumentar/diminuir, cor, duplicar, apagar) ficam na faixa do topo.
///
/// Funciona em coordenadas de tela 1:1 com o canvas porque o modo laço mantém o zoom em 100%.
struct LassoSelectionView: View {
    @ObservedObject var controller: CanvasController

    /// Pontos do laço em desenho (some ao soltar).
    @State private var lassoPoints: [CGPoint] = []
    /// Deslocamento visual da caixa durante o arraste de mover.
    @State private var moveOffset: CGSize = .zero
    /// Último ponto de translação aplicado (para mover por incrementos).
    @State private var lastTranslation: CGSize = .zero
    @State private var movingSelection = false

    var body: some View {
        ZStack {
            // Captura o laço em qualquer ponto da página.
            Color.clear
                .contentShape(Rectangle())
                .gesture(lassoGesture)

            // Traço do laço em andamento (tracejado).
            if lassoPoints.count > 1 {
                lassoPath
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .allowsHitTesting(false)
            }

            // Caixa da seleção (arraste para mover).
            if let b = controller.selectionBounds {
                Rectangle()
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .background(Color.blue.opacity(0.06))
                    .frame(width: b.width + 16, height: b.height + 16)
                    .position(x: b.midX + moveOffset.width, y: b.midY + moveOffset.height)
                    .highPriorityGesture(moveGesture)
            }
        }
    }

    private var lassoPath: Path {
        Path { p in
            guard let first = lassoPoints.first else { return }
            p.move(to: first)
            for pt in lassoPoints.dropFirst() { p.addLine(to: pt) }
            p.closeSubpath()
        }
    }

    /// Desenha o laço e, ao soltar, seleciona a escrita cercada.
    private var lassoGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                lassoPoints.append(value.location)
            }
            .onEnded { _ in
                let poly = lassoPoints
                lassoPoints = []
                if poly.count >= 3 { controller.selectStrokes(inPolygon: poly) }
            }
    }

    /// Arraste dentro da caixa: move a escrita selecionada (um só desfazer no gesto todo).
    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if !movingSelection {
                    movingSelection = true
                    lastTranslation = .zero
                    controller.beginTransform()
                }
                let dx = value.translation.width - lastTranslation.width
                let dy = value.translation.height - lastTranslation.height
                lastTranslation = value.translation
                moveOffset = value.translation
                controller.translateSelectionLive(dx: dx, dy: dy)
            }
            .onEnded { _ in
                controller.endTransform()
                movingSelection = false
                moveOffset = .zero
                lastTranslation = .zero
            }
    }
}
