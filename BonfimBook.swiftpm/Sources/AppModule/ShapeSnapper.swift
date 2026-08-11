import PencilKit
import CoreGraphics

/// Reconhecedor de formas do "modo formas".
///
/// Recebe um traço à mão (`PKStroke`) e, se ele parecer uma LINHA, um RETÂNGULO ou um
/// CÍRCULO/ELIPSE, devolve um novo `PKStroke` com a forma PERFEITA — mesma tinta e espessura.
/// Se não parecer nada disso (um rabisco/curva livre), devolve `nil` e o traço fica como está.
///
/// Não há API nativa de "segurar para virar forma"; isto é pura geometria sobre os pontos do
/// traço. A troca do traço pelo desenho perfeito é sempre reversível (o Coordinator registra
/// o desfazer), então um reconhecimento errado é fácil de cancelar.
enum ShapeSnapper {

    /// Analisa o traço e devolve a forma perfeita, ou `nil` se não reconhecer.
    static func snap(_ stroke: PKStroke) -> PKStroke? {
        // Pontos em coordenadas ABSOLUTAS (aplica o transform do traço).
        let pts = Array(stroke.path).map { $0.location.applying(stroke.transform) }
        guard pts.count >= 8 else { return nil }

        let box = boundingBox(pts)
        let diag = hypot(box.width, box.height)
        // Formas minúsculas costumam ser pontos/acentos — não mexer.
        guard diag > 40 else { return nil }

        let size = averageSize(stroke)
        let firstLast = distance(pts.first!, pts.last!)
        let closed = firstLast < diag * 0.25

        if !closed {
            // Traço aberto: só vira linha reta se for realmente reto.
            if straightError(pts) < 0.07 {
                return makeLine(from: pts.first!, to: pts.last!, ink: stroke.ink,
                                size: size, creation: stroke.path.creationDate)
            }
            return nil
        }

        // Traço fechado: decide entre elipse e retângulo pelo menor erro de ajuste.
        let eErr = ellipseError(pts, box: box)
        let rErr = rectError(pts, box: box)
        guard min(eErr, rErr) < 0.16 else { return nil }

        if eErr <= rErr {
            return makeEllipse(in: box, ink: stroke.ink, size: size,
                               creation: stroke.path.creationDate)
        } else {
            return makeRect(box, ink: stroke.ink, size: size,
                            creation: stroke.path.creationDate)
        }
    }

    // MARK: - Medidas de erro (quanto menor, melhor o encaixe)

    /// Maior desvio dos pontos em relação à reta (ponto inicial → ponto final), em fração do
    /// comprimento da reta. Pequeno = traço reto.
    private static func straightError(_ pts: [CGPoint]) -> CGFloat {
        guard let a = pts.first, let b = pts.last else { return .infinity }
        let len = distance(a, b)
        guard len > 1 else { return .infinity }
        var maxD: CGFloat = 0
        for p in pts {
            maxD = max(maxD, distanceToLine(p, a: a, b: b))
        }
        return maxD / len
    }

    /// Erro médio de encaixe numa elipse inscrita no bounding box (|r - 1|, r adimensional).
    private static func ellipseError(_ pts: [CGPoint], box: CGRect) -> CGFloat {
        let cx = box.midX, cy = box.midY
        let a = max(box.width / 2, 1), b = max(box.height / 2, 1)
        var sum: CGFloat = 0
        for p in pts {
            let r = hypot((p.x - cx) / a, (p.y - cy) / b)
            sum += abs(r - 1)
        }
        return sum / CGFloat(pts.count)
    }

    /// Erro médio de encaixe no CONTORNO do bounding box (distância à borda mais próxima,
    /// em fração da menor meia-dimensão). Pequeno = pontos sobre as arestas = retângulo.
    private static func rectError(_ pts: [CGPoint], box: CGRect) -> CGFloat {
        let half = max(min(box.width, box.height) / 2, 1)
        var sum: CGFloat = 0
        for p in pts {
            let dx = min(abs(p.x - box.minX), abs(box.maxX - p.x))
            let dy = min(abs(p.y - box.minY), abs(box.maxY - p.y))
            sum += min(dx, dy)
        }
        return (sum / CGFloat(pts.count)) / half
    }

    // MARK: - Construção das formas perfeitas

    private static func makeLine(from a: CGPoint, to b: CGPoint, ink: PKInk,
                                 size: CGFloat, creation: Date) -> PKStroke {
        var locs: [CGPoint] = []
        let n = 24
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            locs.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return buildStroke(locs, ink: ink, size: size, creation: creation)
    }

    private static func makeRect(_ box: CGRect, ink: PKInk, size: CGFloat,
                                 creation: Date) -> PKStroke {
        let tl = CGPoint(x: box.minX, y: box.minY)
        let tr = CGPoint(x: box.maxX, y: box.minY)
        let br = CGPoint(x: box.maxX, y: box.maxY)
        let bl = CGPoint(x: box.minX, y: box.maxY)
        var locs: [CGPoint] = []
        // Percorre as 4 arestas (fechando no ponto inicial) interpolando pontos.
        for (from, to) in [(tl, tr), (tr, br), (br, bl), (bl, tl)] {
            let n = 16
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n)
                locs.append(CGPoint(x: from.x + (to.x - from.x) * t,
                                    y: from.y + (to.y - from.y) * t))
            }
        }
        locs.append(tl) // fecha
        return buildStroke(locs, ink: ink, size: size, creation: creation)
    }

    private static func makeEllipse(in box: CGRect, ink: PKInk, size: CGFloat,
                                    creation: Date) -> PKStroke {
        let cx = box.midX, cy = box.midY
        let a = box.width / 2, b = box.height / 2
        var locs: [CGPoint] = []
        let n = 72
        for i in 0...n {
            let ang = (CGFloat(i) / CGFloat(n)) * 2 * .pi
            locs.append(CGPoint(x: cx + a * cos(ang), y: cy + b * sin(ang)))
        }
        return buildStroke(locs, ink: ink, size: size, creation: creation)
    }

    /// Monta um `PKStroke` a partir de posições, com espessura uniforme e caneta perpendicular.
    private static func buildStroke(_ locs: [CGPoint], ink: PKInk, size: CGFloat,
                                    creation: Date) -> PKStroke {
        let w = max(size, 1)
        var points: [PKStrokePoint] = []
        points.reserveCapacity(locs.count)
        for (i, loc) in locs.enumerated() {
            points.append(
                PKStrokePoint(location: loc,
                              timeOffset: TimeInterval(i) * 0.01,
                              size: CGSize(width: w, height: w),
                              opacity: 1,
                              force: 1,
                              azimuth: 0,
                              altitude: .pi / 2)
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: creation)
        return PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
    }

    // MARK: - Geometria auxiliar

    private static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Distância perpendicular do ponto `p` à reta que passa por `a` e `b`.
    private static func distanceToLine(_ p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return distance(p, a) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
    }

    private static func averageSize(_ stroke: PKStroke) -> CGFloat {
        let sizes = Array(stroke.path).map { $0.size.width }
        guard !sizes.isEmpty else { return 3 }
        let avg = sizes.reduce(0, +) / CGFloat(sizes.count)
        return avg > 0 ? avg : 3
    }
}
