import SwiftUI
import UIKit
import Combine

/// Tela de diagnóstico da caneta. Captura toques crus da Apple Pencil e mostra ao vivo:
/// tipo do toque, força/pressão, inclinação (altitude/azimute) e taxa de amostragem.
/// Ao final, um VEREDITO em texto grande orienta a estratégia de espessura do traço.
struct PenDiagnosticView: View {

    @StateObject private var model = PenDiagnosticModel()

    init() {}

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                drawingArea
                metrics
                verdict
                clearButton
            }
            .padding()
        }
    }

    // MARK: - Seções

    private var header: some View {
        VStack(spacing: 4) {
            Text("Diagnóstico da Caneta")
                .font(.title2.bold())
            Text("Descubra o que sua Apple Pencil consegue detectar.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var drawingArea: some View {
        ZStack {
            PenTouchCanvas(model: model)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color(.separator), lineWidth: 1)
                )

            if !model.sawData {
                Text("Rabisque aqui com a caneta")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 280)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricRow("Tipo de toque",
                      model.sawData ? (model.isPencil ? "Caneta (Pencil)" : "Dedo / outro") : "—")
            metricRow("Força",
                      String(format: "%.3f de %.3f", model.force, model.maximumPossibleForce))
            metricRow("Altitude (inclinação)",
                      String(format: "%.2f rad (%.0f°)", model.altitudeAngle, model.altitudeAngle * 180 / .pi))
            metricRow("Azimute (direção)",
                      String(format: "%.2f rad (%.0f°)", model.azimuthAngle, model.azimuthAngle * 180 / .pi))
            metricRow("Taxa de amostragem",
                      String(format: "%.0f pontos/s", model.sampleRate))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .fontWeight(.semibold)
        }
    }

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.pressureDetected
                 ? "Pressão: DETECTADA → espessura por pressão"
                 : "Pressão: AUSENTE → espessura por velocidade")
                .foregroundColor(model.pressureDetected ? .green : .orange)

            Text(model.tiltDetected
                 ? "Inclinação: DETECTADA (aproveitar no lápis/marca-texto)"
                 : "Inclinação: AUSENTE")
                .foregroundColor(model.tiltDetected ? .green : .orange)

            Text("Taxa de amostragem: ~\(Int(model.sampleRate.rounded())) pontos/s")
                .foregroundColor(.primary)
        }
        .font(.title3.bold())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var clearButton: some View {
        Button {
            model.reset()
        } label: {
            Text("Limpar")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44) // alvo de toque >= 44pt
        }
        .buttonStyle(.borderedProminent)
    }
}

// MARK: - Modelo observável (valores ao vivo)

/// Publica os valores do último toque de caneta e mantém as faixas observadas
/// (mín/máx de força e altitude) usadas para o veredito.
@MainActor
final class PenDiagnosticModel: ObservableObject {

    @Published var sawData = false
    @Published var isPencil = false
    @Published var force: CGFloat = 0
    @Published var maximumPossibleForce: CGFloat = 0
    @Published var altitudeAngle: CGFloat = 0
    @Published var azimuthAngle: CGFloat = 0
    @Published var sampleRate: Double = 0

    // Token de limpeza: incrementa a cada reset; a UIView observa e apaga os traços.
    @Published var clearToken = 0

    // Faixas observadas (só de toques de caneta) para decidir o veredito.
    private var forceMin: CGFloat = .greatestFiniteMagnitude
    private var forceMax: CGFloat = 0
    private var altitudeMin: CGFloat = .greatestFiniteMagnitude
    private var altitudeMax: CGFloat = 0

    /// Pressão real: o hardware reporta força máxima > 0 E a força efetivamente variou.
    var pressureDetected: Bool {
        maximumPossibleForce > 0 && forceMax > 0 && (forceMax - forceMin) > 0.001
    }

    /// Inclinação disponível: a altitude variou de forma perceptível (> ~1°).
    var tiltDetected: Bool {
        sawData && (altitudeMax - altitudeMin) > 0.02
    }

    /// Atualiza os valores ao vivo a partir de um toque processado na UIView.
    func update(isPencil: Bool,
                force: CGFloat,
                maxForce: CGFloat,
                altitude: CGFloat,
                azimuth: CGFloat,
                rate: Double) {
        sawData = true
        self.isPencil = isPencil
        self.force = force
        self.maximumPossibleForce = maxForce
        self.altitudeAngle = altitude
        self.azimuthAngle = azimuth
        self.sampleRate = rate

        // Só acumulamos faixas de toques de caneta (dedo tem força 0 e polui a análise).
        if isPencil {
            forceMin = min(forceMin, force)
            forceMax = max(forceMax, force)
            altitudeMin = min(altitudeMin, altitude)
            altitudeMax = max(altitudeMax, altitude)
        }
    }

    func reset() {
        sawData = false
        isPencil = false
        force = 0
        maximumPossibleForce = 0
        altitudeAngle = 0
        azimuthAngle = 0
        sampleRate = 0
        forceMin = .greatestFiniteMagnitude
        forceMax = 0
        altitudeMin = .greatestFiniteMagnitude
        altitudeMax = 0
        clearToken += 1
    }
}

// MARK: - Ponte UIKit: captura de toques crus

/// Envolve a `PenCaptureView` (UIView que recebe touchesBegan/Moved) no mundo SwiftUI.
private struct PenTouchCanvas: UIViewRepresentable {

    @ObservedObject var model: PenDiagnosticModel

    func makeUIView(context: Context) -> PenCaptureView {
        let view = PenCaptureView()
        view.model = model
        return view
    }

    func updateUIView(_ uiView: PenCaptureView, context: Context) {
        // Se o modelo pediu limpeza, apaga os traços desenhados.
        if uiView.appliedClearToken != model.clearToken {
            uiView.appliedClearToken = model.clearToken
            uiView.clearStrokes()
        }
    }
}

/// UIView que captura toques crus, desenha um rabisco de feedback e reporta ao modelo
/// os dados de caneta (tipo, força, altitude/azimute e taxa de amostragem).
final class PenCaptureView: UIView {

    weak var model: PenDiagnosticModel?
    var appliedClearToken = 0

    // Traços desenhados (feedback visual).
    private var strokes: [UIBezierPath] = []
    private var currentPath: UIBezierPath?

    // Janela de timestamps (últimos ~1s) para estimar a taxa de amostragem.
    private var timestamps: [TimeInterval] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }

    // MARK: - Toques

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            let point = touch.location(in: self)
            let path = UIBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: point)
            currentPath = path
            strokes.append(path)
        }
        process(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        process(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        currentPath = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        currentPath = nil
    }

    /// Processa um lote de toques: desenha, estima a taxa e publica os valores.
    private func process(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        // coalescedTouches: todos os pontos intermediários daquele frame (alta taxa).
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for c in coalesced {
            timestamps.append(c.timestamp)
            currentPath?.addLine(to: c.location(in: self))
        }
        trimTimestamps()

        let rate = estimatedRate()
        // azimuthAngle precisa de uma view de referência para o sistema de coordenadas.
        let azimuth = touch.azimuthAngle(in: self)

        model?.update(isPencil: touch.type == .pencil,
                      force: touch.force,
                      maxForce: touch.maximumPossibleForce,
                      altitude: touch.altitudeAngle,
                      azimuth: azimuth,
                      rate: rate)

        setNeedsDisplay()
    }

    // MARK: - Taxa de amostragem

    /// Mantém apenas os timestamps do último 1 segundo.
    private func trimTimestamps() {
        guard let newest = timestamps.last else { return }
        let cutoff = newest - 1.0
        while let first = timestamps.first, first < cutoff {
            timestamps.removeFirst()
        }
    }

    /// Pontos por segundo dentro da janela atual.
    private func estimatedRate() -> Double {
        guard timestamps.count >= 2 else { return 0 }
        let span = timestamps[timestamps.count - 1] - timestamps[0]
        guard span > 0 else { return 0 }
        return Double(timestamps.count - 1) / span
    }

    // MARK: - Desenho e limpeza

    override func draw(_ rect: CGRect) {
        UIColor.label.setStroke()
        for path in strokes {
            path.stroke()
        }
    }

    func clearStrokes() {
        strokes.removeAll()
        currentPath = nil
        timestamps.removeAll()
        setNeedsDisplay()
    }
}
