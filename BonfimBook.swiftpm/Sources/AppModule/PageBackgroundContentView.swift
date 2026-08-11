import SwiftUI
import UIKit
import CadernoCore

/// Desenha o FUNDO de uma página que foi importada de um documento — uma página de PDF
/// ou uma imagem escaneada — no lugar do papel pautado (`PaperBackgroundView`).
///
/// Fica dentro de um `ZStack` como a camada MAIS BAIXA: nada abaixo dela, e por cima vêm
/// a camada de imagens (`PageImageLayerView`) e o canvas do traço à mão (`PKCanvasView`).
/// Quem monta o `ZStack` — o integrador — cuida da ordem-z; aqui só EXIBIMOS. Esta view
/// é puramente visual e NÃO recebe gestos.
///
/// Regra do contrato: documento parece papel, então há sempre uma base branca por baixo
/// (mesmo enquanto a imagem do fundo ainda está carregando).
struct PageBackgroundContentView: View {
    let store: NotebookStore
    let background: PageBackground

    /// Imagem do fundo já rasterizada/carregada. Fica em `@State` e é preenchida UMA vez
    /// (ver `.task`), porque rasterizar um PDF a cada recomputação do `body` seria caro.
    @State private var image: UIImage?

    /// Chave que identifica QUAL fundo estamos exibindo. Combina o asset e — para PDF — o
    /// índice da página; se qualquer um mudar, o `.task` reexecuta e recarrega a imagem.
    private var taskKey: String {
        "\(background.assetID)#\(background.pdfPageIndex ?? 0)"
    }

    var body: some View {
        ZStack {
            // Base branca sempre presente: preenche toda a área do container.
            Color.white

            if let image {
                // Fundo carregado: encaixa por completo (scaledToFit) e centraliza.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Ainda carregando: só a base branca com um indicador sutil ao centro.
                ProgressView()
            }
        }
        // Carrega o fundo de forma preguiçosa e o recarrega se `taskKey` mudar.
        .task(id: taskKey) {
            await loadImage()
        }
    }

    // MARK: - Carregamento (preguiçoso e fora da main thread)

    /// Carrega a imagem do fundo conforme o tipo (`.image` ou `.pdf`).
    ///
    /// A rasterização de PDF pode ser lenta, então acontece FORA da main thread (via
    /// `Task.detached`) e o resultado só é atribuído ao `@State` de volta na main thread.
    ///
    /// Gotcha do projeto: como esta é uma `struct View`, NÃO capturamos `self` dentro do
    /// closure concorrente; copiamos os locais necessários (`store`, `background`) antes de
    /// despachar e usamos apenas eles no trabalho de fundo.
    @MainActor
    private func loadImage() async {
        // Copia os valores necessários ANTES de sair da main thread (nada de `self` lá dentro).
        let store = self.store
        let background = self.background

        // Trabalho pesado numa tarefa destacada, em prioridade de usuário.
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let fileURL = store.assetFileURL(id: background.assetID)
            switch background.kind {
            case .image:
                // Lê a imagem direto do arquivo do asset.
                return UIImage(contentsOfFile: fileURL.path)
            case .pdf:
                // Rasteriza a página do PDF em 2x para boa nitidez em tela Retina.
                return PDFRasterizer.image(
                    fileURL: fileURL,
                    pageIndex: background.pdfPageIndex ?? 0,
                    scale: 2
                )
            }
        }.value

        // De volta à main thread (garantida pelo `@MainActor`): publica o resultado.
        self.image = loaded
    }
}
