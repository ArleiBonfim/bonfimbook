import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

/// Suporte à IMPORTAÇÃO de PDFs para dentro do caderno: um seletor de arquivo (SwiftUI) e um
/// rasterizador de páginas (PDFKit). São duas peças independentes e sem estado compartilhado.
///
/// Contrato geral:
///  - Nada aqui derruba o app: entradas inválidas (arquivo ilegível, índice fora da faixa,
///    PDF corrompido) resultam em cancelamento/`nil`, nunca em crash.
///  - O seletor pede UMA cópia legível temporária (`asCopy: true`), então quem recebe os bytes
///    não precisa lidar com "security-scoped resources".

// MARK: - Seletor de PDF (SwiftUI ↔ UIKit)

/// Wrapper SwiftUI do seletor de documentos do sistema (`UIDocumentPickerViewController`),
/// configurado para escolher UM único arquivo PDF.
///
/// Ao escolher, entrega os BYTES do PDF (já copiados para um arquivo temporário legível). Nunca
/// acessa o sistema de arquivos do usuário diretamente — o picker roda fora do processo e só
/// devolve o que foi escolhido, sem exigir permissão de disco.
struct PDFDocumentPicker: UIViewControllerRepresentable {
    /// Bytes do PDF escolhido. Sempre chamado na MAIN thread.
    var onPick: (Data) -> Void
    /// Cancelou, veio vazio ou falhou a leitura dos bytes. Também na MAIN thread.
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `asCopy: true` -> o sistema entrega uma CÓPIA temporária legível (sem precisar de
        // `startAccessingSecurityScopedResource`). Ótimo para simplesmente ler os bytes.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf],
                                                    asCopy: true)
        picker.allowsMultipleSelection = false      // um arquivo por vez
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        // Nada a atualizar: o seletor não tem estado dinâmico vindo do SwiftUI.
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        // Guardamos as CLOSURES (não a struct PDFDocumentPicker), pois a struct é recriada a
        // cada atualização de layout. As closures são o contrato estável com quem nos usa.
        private let onPick: (Data) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            // Capturamos as closures em LOCAIS antes de qualquer trabalho: assim o restante não
            // depende de estado mutável do coordinator (gotcha do projeto sobre captura de
            // `self` em closures concorrentes).
            let onPick = self.onPick
            let onCancel = self.onCancel

            guard let url = urls.first else {
                // Nenhuma URL = nada a importar.
                DispatchQueue.main.async { onCancel() }
                return
            }

            // Como pedimos `asCopy: true`, `url` é uma cópia temporária já legível — basta ler.
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                DispatchQueue.main.async { onCancel() }
                return
            }

            DispatchQueue.main.async { onPick(data) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            let onCancel = self.onCancel
            DispatchQueue.main.async { onCancel() }
        }
    }
}

// MARK: - Rasterizador de PDF (PDFKit → UIImage)

/// Converte páginas de um arquivo PDF em imagens (bitmaps), para exibição/edição dentro do
/// caderno. Só LÊ o arquivo — nunca escreve. Robusto a entradas inválidas: retorna 0 / `nil`.
enum PDFRasterizer {

    /// Quantidade de páginas do PDF em `fileURL`. Retorna 0 se o arquivo não puder ser aberto
    /// (inexistente, sem permissão, corrompido, ou não é um PDF válido).
    static func pageCount(fileURL: URL) -> Int {
        guard let document = PDFDocument(url: fileURL) else { return 0 }
        return document.pageCount
    }

    /// Rasteriza a página `pageIndex` (base 0) de `fileURL` numa `UIImage`, ampliada por
    /// `scale` (ex.: 2 para nitidez retina). Retorna `nil` se:
    ///  - o documento não abrir;
    ///  - `pageIndex` estiver fora da faixa [0, pageCount);
    ///  - o tamanho da página for degenerado (largura/altura ≤ 0).
    ///
    /// O fundo é preenchido de BRANCO primeiro (páginas de PDF podem ser transparentes) e, em
    /// seguida, a página é desenhada. Como o PDFKit desenha no espaço de coordenadas do PDF
    /// (origem embaixo-à-esquerda), invertemos o eixo Y do contexto para casar com o topo-à-
    /// esquerda do UIKit.
    static func image(fileURL: URL, pageIndex: Int, scale: CGFloat) -> UIImage? {
        guard let document = PDFDocument(url: fileURL) else { return nil }
        guard pageIndex >= 0, pageIndex < document.pageCount else { return nil }
        guard let page = document.page(at: pageIndex) else { return nil }

        // Tamanho lógico da página, em pontos, pela caixa de mídia (a "folha" do PDF).
        let pageBounds = page.bounds(for: .mediaBox)
        let pageSize = pageBounds.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }

        // A escala é aplicada pelo FORMAT (scale = `scale`); mantemos o tamanho em pontos e
        // deixamos o renderer produzir o bitmap ampliado. `opaque = true` porque pintamos o
        // fundo de branco (sem transparência no resultado final).
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
        return renderer.image { rendererContext in
            let cg = rendererContext.cgContext
            let bounds = CGRect(origin: .zero, size: pageSize)

            // 1) Fundo branco (páginas de PDF podem ser transparentes).
            UIColor.white.setFill()
            cg.fill(bounds)

            // 2) Inverte o eixo Y: PDFKit desenha de baixo-para-cima; o UIKit espera o topo em y=0.
            cg.translateBy(x: 0, y: pageSize.height)
            cg.scaleBy(x: 1, y: -1)

            // 3) Desenha a página no contexto já orientado.
            page.draw(with: .mediaBox, to: cg)
        }
    }
}
