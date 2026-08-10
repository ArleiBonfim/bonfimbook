import SwiftUI
import CadernoCore

/// Desenha o PAPEL de uma página (fundo + padrão do template).
///
/// Ferramenta puramente visual e SEM estado: recebe apenas o `PaperTemplate` e
/// preenche o espaço disponível do container. O `PKCanvasView` (transparente) fica
/// por cima deste papel — ver `PKCanvasRepresentable`.
///
/// Regra do contrato: o papel é CLARO SEMPRE, não depende de dark mode (papel é papel).
struct PaperBackgroundView: View {
    let template: PaperTemplate

    // MARK: - Paleta (fixa, independente de dark mode)

    /// Cor do papel — off-white levemente quente.
    private static let paperColor = Color(red: 0.99, green: 0.99, blue: 0.97)
    /// Cor sutil das linhas/pontos/quadriculado.
    private static let lineColor = Color(red: 0.85, green: 0.87, blue: 0.92)
    /// Margem vertical vermelha clara (pautado/Cornell).
    private static let marginColor = Color(red: 0.90, green: 0.65, blue: 0.65)

    // MARK: - Métricas do padrão

    private static let ruledSpacing: CGFloat = 34
    private static let gridSpacing: CGFloat = 24
    private static let dottedSpacing: CGFloat = 24
    private static let dotRadius: CGFloat = 1
    private static let marginInset: CGFloat = 44

    var body: some View {
        Canvas { context, size in
            // Fundo de papel claro, sempre.
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Self.paperColor)
            )

            switch template {
            case .blank:
                break // só o papel
            case .ruled:
                drawRuled(in: &context, size: size)
            case .grid:
                drawGrid(in: &context, size: size)
            case .dotted:
                drawDotted(in: &context, size: size)
            case .cornell:
                drawCornell(in: &context, size: size)
            }
        }
        // Preenche o container e recorta o padrão às bordas.
        .clipped()
    }

    // MARK: - Desenho dos padrões

    /// Linhas horizontais + margem vertical vermelha à esquerda.
    private func drawRuled(in context: inout GraphicsContext, size: CGSize) {
        drawHorizontalLines(in: &context, size: size, spacing: Self.ruledSpacing)
        drawLeftMargin(in: &context, size: size)
    }

    /// Quadriculado (linhas horizontais + verticais).
    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        var y = Self.gridSpacing
        while y < size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += Self.gridSpacing
        }
        var x = Self.gridSpacing
        while x < size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += Self.gridSpacing
        }
        context.stroke(path, with: .color(Self.lineColor), lineWidth: 0.5)
    }

    /// Malha de pontos.
    private func drawDotted(in context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        var y = Self.dottedSpacing
        while y < size.height {
            var x = Self.dottedSpacing
            while x < size.width {
                let rect = CGRect(
                    x: x - Self.dotRadius,
                    y: y - Self.dotRadius,
                    width: Self.dotRadius * 2,
                    height: Self.dotRadius * 2
                )
                path.addEllipse(in: rect)
                x += Self.dottedSpacing
            }
            y += Self.dottedSpacing
        }
        context.fill(path, with: .color(Self.lineColor))
    }

    /// Cornell: pautado + coluna de "dica" (~28% da largura) + faixa de "resumo" na base (~18%).
    private func drawCornell(in context: inout GraphicsContext, size: CGSize) {
        let summaryHeight = size.height * 0.18
        let notesBottom = size.height - summaryHeight
        let cueX = size.width * 0.28

        // Pautado apenas na área de notas (acima da faixa de resumo).
        var lines = Path()
        var y = Self.ruledSpacing
        while y < notesBottom {
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
            y += Self.ruledSpacing
        }
        context.stroke(lines, with: .color(Self.lineColor), lineWidth: 0.5)

        // Linha vertical de "dica" (da margem superior até a faixa de resumo).
        var cue = Path()
        cue.move(to: CGPoint(x: cueX, y: 0))
        cue.addLine(to: CGPoint(x: cueX, y: notesBottom))
        context.stroke(cue, with: .color(Self.lineColor), lineWidth: 1)

        // Linha horizontal separando a faixa de resumo.
        var summary = Path()
        summary.move(to: CGPoint(x: 0, y: notesBottom))
        summary.addLine(to: CGPoint(x: size.width, y: notesBottom))
        context.stroke(summary, with: .color(Self.lineColor), lineWidth: 1)
    }

    // MARK: - Helpers

    private func drawHorizontalLines(in context: inout GraphicsContext, size: CGSize, spacing: CGFloat) {
        var path = Path()
        var y = spacing
        while y < size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += spacing
        }
        context.stroke(path, with: .color(Self.lineColor), lineWidth: 0.5)
    }

    private func drawLeftMargin(in context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: Self.marginInset, y: 0))
        path.addLine(to: CGPoint(x: Self.marginInset, y: size.height))
        context.stroke(path, with: .color(Self.marginColor), lineWidth: 1)
    }
}
