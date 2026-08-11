import UIKit
import Vision
import CoreImage

/// Remove o fundo de uma imagem, deixando só o objeto principal com fundo TRANSPARENTE —
/// tudo NO PRÓPRIO iPad (Vision da Apple), sem enviar nada pra fora. Ótimo para colar
/// figuras/clipart na anotação sem aquele quadrado de fundo.
///
/// Requer iPadOS 17+ (API `VNGenerateForegroundInstanceMaskRequest`). A chamada é protegida
/// por disponibilidade em quem usa.
@available(iOS 17.0, *)
enum BackgroundRemover {

    /// Devolve uma nova imagem (PNG com transparência) só com o objeto em destaque, ou `nil`
    /// se não achar um objeto claro / falhar.
    static func removeBackground(from image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let result = request.results?.first else { return nil }

        do {
            // Gera a imagem só com os objetos em destaque e fundo transparente.
            let masked = try result.generateMaskedImage(ofInstances: result.allInstances,
                                                         from: handler,
                                                         croppedToInstancesExtent: false)
            let ciImage = CIImage(cvPixelBuffer: masked)
            let context = CIContext()
            guard let out = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: out)
        } catch {
            return nil
        }
    }
}
