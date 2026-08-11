import UIKit
import PencilKit
import CadernoCore

/// Exporta um caderno inteiro para um único arquivo PDF (uma página do PDF por página do
/// caderno), pronto para compartilhar via `ShareSheet`.
///
/// Estratégia: reproduzimos AQUI, com Core Graphics, o mesmo papel que o `PaperBackgroundView`
/// desenha na tela — mesmas cores, mesmas métricas — para o PDF sair idêntico ao que o usuário
/// vê. Por cima do papel vão as imagens (assets) e, por último, o traço à mão (PKDrawing
/// rasterizado). O Core (`NotebookStore`) continua sendo a única fonte da verdade; este tipo
/// só LÊ dados e nunca escreve no pacote.
///
/// Regras do contrato respeitadas:
///  - Espaço de coordenadas FIXO de 768x1024 pt (origem no topo-esquerda), igual ao da tela.
///  - Papel é SEMPRE claro (nunca depende de dark mode).
///  - Nunca derruba o app: entradas inválidas (asset ilegível, traço corrompido) são puladas.
enum PDFExporter {

    // MARK: - Erros

    /// Erro dedicado da exportação, para o chamador distinguir falha de PDF de outros erros.
    enum PDFExportError: Error {
        case failed(String)
    }

    // MARK: - Dimensões lógicas da página (idênticas às da tela)

    /// Largura lógica da página em pontos (retrato, proporção 3:4).
    private static let pageWidth: CGFloat = 768
    /// Altura lógica da página em pontos.
    private static let pageHeight: CGFloat = 1024
    /// Escala de rasterização do traço à mão (2x para nitidez em telas retina/impressão).
    private static let renderScale: CGFloat = 2

    // MARK: - Paleta do papel (fixa, cópia exata de PaperBackgroundView)

    /// Cor do papel — off-white levemente quente.
    private static let paperColor = UIColor(red: 0.99, green: 0.99, blue: 0.97, alpha: 1)
    /// Cor sutil das linhas/pontos/quadriculado.
    private static let lineColor = UIColor(red: 0.85, green: 0.87, blue: 0.92, alpha: 1)
    /// Margem vertical vermelha clara (pautado/Cornell).
    private static let marginColor = UIColor(red: 0.90, green: 0.65, blue: 0.65, alpha: 1)

    // MARK: - Métricas do padrão (em pontos, cópia exata de PaperBackgroundView)

    private static let ruledSpacing: CGFloat = 34
    private static let gridSpacing: CGFloat = 24
    private static let dottedSpacing: CGFloat = 24
    private static let dotRadius: CGFloat = 1
    private static let marginInset: CGFloat = 44

    // MARK: - API pública

    /// Gera o PDF do caderno e devolve a URL de um arquivo temporário pronto para partilha.
    ///
    /// O nome do arquivo vem do título do caderno (higienizado); se ele já existir no diretório
    /// temporário, é sobrescrito (a exportação sempre reflete o estado atual do caderno).
    static func makePDF(store: NotebookStore) throws -> URL {
        // Título só para nomear o arquivo — não influencia o conteúdo renderizado.
        let manifest = try store.loadManifest()
        let pages = try store.pages()

        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        // Renderiza tudo em memória; `pdfData(actions:)` não lança, então erros de leitura de
        // dados (asset/traço) são tratados por página, sem abortar o documento inteiro.
        let data = renderer.pdfData { rendererContext in
            for page in pages {
                rendererContext.beginPage()
                let cg = rendererContext.cgContext

                // 1) Fundo: documento importado (PDF/imagem) OU papel do template.
                if let bg = page.background {
                    drawBackground(bg, store: store, in: cg, rect: pageRect)
                } else {
                    // Template desconhecido cai em `.blank`.
                    let template = PaperTemplate(rawValue: page.template) ?? .blank
                    drawPaper(template: template, in: cg, rect: pageRect)
                }

                // 2) Imagens (por baixo do traço). Falha de leitura de um asset é ignorada.
                if let elements = page.elements {
                    for element in elements {
                        drawElement(element, store: store, in: cg)
                    }
                }

                // 3) Traço à mão (por cima de tudo).
                drawHandwriting(pageID: page.id, store: store, in: cg, rect: pageRect)
            }
        }

        // Escreve num arquivo temporário com nome derivado do título.
        let fileName = safeFileName(manifest.title) + ".pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        // Sobrescreve se já houver um PDF antigo com esse nome.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw PDFExportError.failed("falha ao gravar o PDF: \(error.localizedDescription)")
        }
        return url
    }

    // MARK: - Exportar UMA página como imagem (PNG)

    /// Renderiza uma única página (fundo/papel + imagens + traço) num PNG e devolve a URL de
    /// um arquivo temporário para partilha. Reaproveita exatamente os mesmos desenhos do PDF.
    static func makePagePNG(store: NotebookStore, page: PageMeta) throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = renderScale
        let renderer = UIGraphicsImageRenderer(bounds: pageRect, format: format)

        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            if let bg = page.background {
                drawBackground(bg, store: store, in: cg, rect: pageRect)
            } else {
                let template = PaperTemplate(rawValue: page.template) ?? .blank
                drawPaper(template: template, in: cg, rect: pageRect)
            }
            if let elements = page.elements {
                for element in elements { drawElement(element, store: store, in: cg) }
            }
            drawHandwriting(pageID: page.id, store: store, in: cg, rect: pageRect)
        }

        guard let data = image.pngData() else {
            throw PDFExportError.failed("não foi possível gerar o PNG da página")
        }

        let title = (try? store.loadManifest().title) ?? "Caderno"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeFileName(title) + ".png")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw PDFExportError.failed("falha ao gravar o PNG: \(error.localizedDescription)")
        }
        return url
    }

    // MARK: - Desenho do fundo importado (PDF/imagem)

    /// Desenha o fundo de uma página que veio de um documento: base branca + a página do PDF
    /// (rasterizada) ou a imagem escaneada, ambas ajustadas por proporção (aspect-fit) e
    /// centralizadas. Falha de leitura deixa só o branco (nunca derruba o documento).
    private static func drawBackground(_ bg: PageBackground, store: NotebookStore,
                                       in cg: CGContext, rect: CGRect) {
        UIColor.white.setFill()
        cg.fill(rect)

        let image: UIImage?
        switch bg.kind {
        case .image:
            image = UIImage(contentsOfFile: store.assetFileURL(id: bg.assetID).path)
        case .pdf:
            image = PDFRasterizer.image(fileURL: store.assetFileURL(id: bg.assetID),
                                        pageIndex: bg.pdfPageIndex ?? 0,
                                        scale: renderScale)
        }
        guard let img = image else { return }
        img.draw(in: aspectFitRect(imageSize: img.size, in: rect))
    }

    /// Retângulo que encaixa `imageSize` dentro de `rect` preservando a proporção, centralizado.
    private static func aspectFitRect(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: - Desenho de uma imagem (elemento)

    /// Desenha um `PageElement` de imagem no retângulo (x,y,width,height), aplicando a rotação
    /// (radianos) em torno do centro quando houver. Assets ilegíveis/indecodificáveis são pulados.
    private static func drawElement(_ element: PageElement, store: NotebookStore, in cg: CGContext) {
        // Caixa de texto: desenha o texto e retorna (não tem asset de imagem).
        if element.kind == .text {
            drawTextElement(element)
            return
        }

        // `readAsset` pode lançar E devolve `Data?`; `try?` já achata o duplo-opcional para
        // `Data?`, então UM `guard let` basta (um segundo desempacotamento não compila).
        guard let data = try? store.readAsset(id: element.assetID),
              let image = UIImage(data: data) else {
            return
        }

        let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)

        if element.rotation != 0 {
            // Rotação em torno do CENTRO do retângulo: salva o estado, translada até o centro,
            // gira, e desenha centrado na origem transladada.
            cg.saveGState()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            cg.translateBy(x: center.x, y: center.y)
            cg.rotate(by: CGFloat(element.rotation))
            let centered = CGRect(x: -rect.width / 2, y: -rect.height / 2,
                                  width: rect.width, height: rect.height)
            image.draw(in: centered)
            cg.restoreGState()
        } else {
            image.draw(in: rect)
        }
    }

    // MARK: - Desenho de uma caixa de texto

    /// Desenha o texto de um `PageElement` de texto no seu retângulo, com a fonte/cor salvas.
    /// Texto vazio não desenha nada. (Rotação de texto não é suportada nesta versão.)
    private static func drawTextElement(_ element: PageElement) {
        guard let text = element.text, !text.isEmpty else { return }
        let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: CGFloat(element.fontSize ?? 20)),
            .foregroundColor: uiColor(hex: element.colorHex) ?? UIColor.black
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    /// "#RRGGBB"/"RRGGBB" → UIColor; nil se não parsear.
    private static func uiColor(hex raw: String?) -> UIColor? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255.0,
                       green: CGFloat((value >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(value & 0xFF) / 255.0,
                       alpha: 1)
    }

    // MARK: - Desenho do traço à mão

    /// Rasteriza o `PKDrawing` da página (a 2x) e o desenha ocupando a página inteira. Se a
    /// página não tem traço, ou os bytes estão corrompidos, simplesmente não desenha nada.
    private static func drawHandwriting(pageID: String, store: NotebookStore,
                                        in cg: CGContext, rect: CGRect) {
        guard let data = try? store.readDrawing(pageID: pageID),
              let drawing = try? PKDrawing(data: data) else {
            return
        }
        // `image(from:scale:)` produz um bitmap com só o traço (fundo transparente), que
        // desenhamos por cima do papel e das imagens.
        let image = drawing.image(from: rect, scale: renderScale)
        image.draw(in: rect)
    }

    // MARK: - Desenho do papel (mesma lógica de PaperBackgroundView, via Core Graphics)

    /// Preenche o papel de fundo e, conforme o template, o padrão por cima.
    private static func drawPaper(template: PaperTemplate, in cg: CGContext, rect: CGRect) {
        // Fundo de papel claro, sempre.
        paperColor.setFill()
        cg.fill(rect)

        switch template {
        case .blank:
            break // só o papel
        case .ruled:
            drawRuled(in: cg, rect: rect)
        case .grid:
            drawGrid(in: cg, rect: rect)
        case .dotted:
            drawDotted(in: cg, rect: rect)
        case .cornell:
            drawCornell(in: cg, rect: rect)
        }
    }

    /// Pautado: linhas horizontais + margem vertical vermelha à esquerda.
    private static func drawRuled(in cg: CGContext, rect: CGRect) {
        drawHorizontalLines(in: cg, rect: rect, spacing: ruledSpacing, until: rect.height)

        // Margem vertical (linha 1pt vermelha) em x = marginInset, de topo a base.
        let margin = UIBezierPath()
        margin.move(to: CGPoint(x: marginInset, y: 0))
        margin.addLine(to: CGPoint(x: marginInset, y: rect.height))
        marginColor.setStroke()
        margin.lineWidth = 1
        margin.stroke()
    }

    /// Quadriculado: linhas horizontais + verticais a cada 24pt.
    private static func drawGrid(in cg: CGContext, rect: CGRect) {
        let path = UIBezierPath()
        var y = gridSpacing
        while y < rect.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
            y += gridSpacing
        }
        var x = gridSpacing
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: rect.height))
            x += gridSpacing
        }
        lineColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    /// Malha de pontos preenchidos (raio 1) numa grade de 24pt.
    private static func drawDotted(in cg: CGContext, rect: CGRect) {
        let path = UIBezierPath()
        var y = dottedSpacing
        while y < rect.height {
            var x = dottedSpacing
            while x < rect.width {
                let dotRect = CGRect(x: x - dotRadius, y: y - dotRadius,
                                     width: dotRadius * 2, height: dotRadius * 2)
                path.append(UIBezierPath(ovalIn: dotRect))
                x += dottedSpacing
            }
            y += dottedSpacing
        }
        lineColor.setFill()
        path.fill()
    }

    /// Cornell: pautado só na área de notas + coluna de "dica" (~28%) + faixa de "resumo" (~18%).
    private static func drawCornell(in cg: CGContext, rect: CGRect) {
        let summaryHeight = rect.height * 0.18
        let notesBottom = rect.height - summaryHeight
        let cueX = rect.width * 0.28

        // Pautado apenas acima da faixa de resumo.
        drawHorizontalLines(in: cg, rect: rect, spacing: ruledSpacing, until: notesBottom)

        // Linha vertical de "dica" (do topo até a faixa de resumo) e o separador do resumo.
        let structure = UIBezierPath()
        structure.move(to: CGPoint(x: cueX, y: 0))
        structure.addLine(to: CGPoint(x: cueX, y: notesBottom))
        structure.move(to: CGPoint(x: 0, y: notesBottom))
        structure.addLine(to: CGPoint(x: rect.width, y: notesBottom))
        lineColor.setStroke()
        structure.lineWidth = 1
        structure.stroke()
    }

    // MARK: - Helper de linhas horizontais

    /// Traça linhas horizontais (0.5pt, cor de linha) a cada `spacing`, começando em `spacing`
    /// e enquanto `y < limit`.
    private static func drawHorizontalLines(in cg: CGContext, rect: CGRect,
                                            spacing: CGFloat, until limit: CGFloat) {
        let path = UIBezierPath()
        var y = spacing
        while y < limit {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
            y += spacing
        }
        lineColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    // MARK: - Nome de arquivo seguro

    /// Higieniza o título para um nome de arquivo válido (remove separadores, `:`, controle etc.).
    /// Devolve "Caderno" quando sobra vazio, para o arquivo nunca nascer sem nome.
    private static func safeFileName(_ raw: String) -> String {
        var illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        illegal.formUnion(.controlCharacters)
        let cleaned = raw.components(separatedBy: illegal).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Caderno" : cleaned
    }
}
