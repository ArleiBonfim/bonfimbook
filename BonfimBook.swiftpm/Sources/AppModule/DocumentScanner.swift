import SwiftUI
import UIKit
import VisionKit

/// Ponte SwiftUI ↔ UIKit para a câmera de digitalização de documentos da Apple
/// (`VNDocumentCameraViewController`, do framework VisionKit).
///
/// Apresenta a interface nativa de scanner (detecção de bordas, correção de perspectiva,
/// múltiplas páginas). Ao concluir, entrega cada página já convertida em JPEG (`Data`),
/// pronta para virar um asset de imagem no caderno.
///
/// Este controlador EXIGE a câmera. A permissão de câmera é declarada no nível do app
/// (Info.plist do pacote) e é o próprio sistema quem pede ao usuário no momento em que o
/// controlador é apresentado — por isso não há nenhum código de permissão aqui.
///
/// Uso típico: apresentar via `.sheet` ou `.fullScreenCover` (o scanner é uma experiência
/// de tela cheia, então `.fullScreenCover` costuma casar melhor).
struct DocumentScanner: UIViewControllerRepresentable {
    /// Digitalização concluída: uma entrada por página, em JPEG. Sempre na MAIN thread.
    var onFinish: ([Data]) -> Void
    /// Usuário cancelou a digitalização. Sempre na MAIN thread.
    var onCancel: () -> Void
    /// Falha na câmera/digitalização. Sempre na MAIN thread.
    var onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel, onError: onError)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {
        // Nada a atualizar: o scanner não tem estado dinâmico vindo do SwiftUI.
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        // Guardamos as CLOSURES (não a struct DocumentScanner), pois a struct é recriada a
        // cada atualização de layout. As closures são o contrato estável com quem nos usa.
        private let onFinish: ([Data]) -> Void
        private let onCancel: () -> Void
        private let onError: (Error) -> Void

        init(
            onFinish: @escaping ([Data]) -> Void,
            onCancel: @escaping () -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.onFinish = onFinish
            self.onCancel = onCancel
            self.onError = onError
        }

        // MARK: - VNDocumentCameraViewControllerDelegate

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // Capturamos a closure em um LOCAL antes de montar o array de JPEGs. Assim o
            // trecho que percorre as páginas não depende de um `self` capturado em contexto
            // concorrente (gotcha do projeto sobre captura de `var self` em closures).
            let onFinish = self.onFinish

            // Uma entrada por página; páginas que falharem ao codificar em JPEG são puladas.
            var datas: [Data] = []
            datas.reserveCapacity(scan.pageCount)
            for i in 0..<scan.pageCount {
                let image = scan.imageOfPage(at: i)
                if let jpeg = image.jpegData(compressionQuality: 0.8) {
                    datas.append(jpeg)
                }
            }

            // Fecha o scanner sempre, independentemente do resultado.
            controller.dismiss(animated: true)
            DispatchQueue.main.async { onFinish(datas) }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            let onError = self.onError
            controller.dismiss(animated: true)
            DispatchQueue.main.async { onError(error) }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            let onCancel = self.onCancel
            controller.dismiss(animated: true)
            DispatchQueue.main.async { onCancel() }
        }
    }
}
