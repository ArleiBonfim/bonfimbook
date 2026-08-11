import Foundation
import Vision
import UIKit

/// Reconhecimento de texto (impresso e manuscrito) numa imagem, usando o Vision da Apple —
/// tudo NO PRÓPRIO iPad, sem enviar nada pra fora. É "melhor esforço": vai muito bem em
/// letra de forma e em texto digitado/escaneado; em letra cursiva o resultado varia.
enum OCRService {

    /// Devolve o texto reconhecido na imagem (linhas separadas por "\n"), ou "" se nada.
    static func recognizeText(in image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Prioriza português; inglês como reserva (fórmulas, termos).
        request.recognitionLanguages = ["pt-BR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
