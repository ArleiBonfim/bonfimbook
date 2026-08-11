import SwiftUI
import CadernoCore

/// Camada de OBJETOS (imagens) sobreposta a uma página.
///
/// Fica dentro de um `ZStack`, ACIMA do `PaperBackgroundView` (o papel) e ABAIXO do
/// `PKCanvasView` (o traço à mão). Quem monta o `ZStack` — o integrador — decide a
/// ordem-z e se esta camada recebe toques (hit-test); aqui só desenhamos, selecionamos,
/// movemos e redimensionamos os `PageElement`.
///
/// Espaço de coordenadas: PONTOS, origem no topo-esquerda, o MESMO de
/// `PageElement.x/y/width/height` (e do canvas). Como `.position` do SwiftUI usa o
/// CENTRO do elemento, convertemos topo-esquerda → centro na hora de posicionar.
struct PageImageLayerView: View {
    let store: NotebookStore
    @Binding var elements: [PageElement]
    @Binding var selectedElementID: String?
    /// Chamado ao FIM de um gesto (mover/redimensionar) ou ao apagar, para persistir.
    var onCommit: ([PageElement]) -> Void
    /// Pedido para editar o texto de uma caixa de texto (a tela do caderno abre o editor).
    var onEditText: (PageElement) -> Void
    /// Pedido para remover o fundo de uma imagem (a tela do caderno processa e troca o asset).
    var onRemoveBackground: (PageElement) -> Void

    var body: some View {
        // ZStack sem tamanho próprio: cada filho se posiciona por conta própria via
        // `.position`, então a camada ocupa naturalmente o espaço do container.
        ZStack {
            ForEach(elements) { element in
                ImageElementView(
                    store: store,
                    element: element,
                    isSelected: element.id == selectedElementID,
                    onSelect: { selectedElementID = element.id },
                    onDelete: { deleteElement(id: element.id) },
                    onMove: { newX, newY in
                        updateElement(id: element.id) { el in
                            el.x = newX
                            el.y = newY
                        }
                        onCommit(elements)
                    },
                    onResize: { newWidth, newHeight in
                        updateElement(id: element.id) { el in
                            // Para TEXTO, escala também a fonte na mesma proporção da largura,
                            // para o texto crescer/encolher junto com a caixa.
                            if el.kind == .text, let fs = el.fontSize, el.width > 0 {
                                let ratio = newWidth / el.width
                                el.fontSize = max(6, min(400, fs * ratio))
                            }
                            // Mantém o elemento centrado no MESMO ponto após o zoom:
                            // guarda o centro atual e recoloca a origem topo-esquerda.
                            let centerX = el.x + el.width / 2
                            let centerY = el.y + el.height / 2
                            el.width = newWidth
                            el.height = newHeight
                            el.x = centerX - newWidth / 2
                            el.y = centerY - newHeight / 2
                        }
                        onCommit(elements)
                    },
                    onEdit: { onEditText(element) },
                    onRemoveBackground: { onRemoveBackground(element) }
                )
            }
        }
    }

    // MARK: - Mutação segura do array

    /// Aplica `mutate` ao elemento de `id` dado, se existir. Encapsula a busca do índice
    /// para nunca indexar o array fora dos limites (o elemento pode ter sido removido).
    private func updateElement(id: String, _ mutate: (inout PageElement) -> Void) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        mutate(&elements[index])
    }

    /// Remove o elemento, limpa a seleção se era ele, e persiste.
    private func deleteElement(id: String) {
        elements.removeAll { $0.id == id }
        if selectedElementID == id {
            selectedElementID = nil
        }
        onCommit(elements)
    }
}

// MARK: - View de um único elemento-imagem

/// Desenha UMA imagem da página e concentra os gestos de mover/redimensionar.
///
/// Cada instância guarda o estado TRANSITÓRIO do gesto em andamento (deslocamento do
/// arraste e fator da pinça); ao terminar o gesto, comunica o valor final ao pai pelas
/// closures `onMove`/`onResize`, que é quem escreve no `Binding` e persiste.
private struct ImageElementView: View {
    let store: NotebookStore
    let element: PageElement
    let isSelected: Bool
    var onSelect: () -> Void
    var onDelete: () -> Void
    var onMove: (Double, Double) -> Void    // (novoX, novoY) em topo-esquerda
    var onResize: (Double, Double) -> Void  // (novaLargura, novaAltura)
    var onEdit: () -> Void                  // editar o texto (só caixas de texto)
    var onRemoveBackground: () -> Void      // remover o fundo (só imagens)

    /// Deslocamento em curso do arraste (some ao terminar). Só o selecionado arrasta.
    @State private var dragOffset: CGSize = .zero
    /// Fator de escala em curso da pinça (volta a 1 automaticamente ao terminar).
    @GestureState private var pinchScale: CGFloat = 1

    // Limites de redimensionamento (preservando proporção).
    private static let minSide: Double = 40
    private static let maxSide: Double = 4000

    // Tamanho exibido = tamanho persistido × pinça em curso.
    private var displayWidth: CGFloat { CGFloat(element.width) * pinchScale }
    private var displayHeight: CGFloat { CGFloat(element.height) * pinchScale }

    // Centro exibido: origem topo-esquerda → centro (+ deslocamento do arraste).
    private var displayCenterX: CGFloat {
        CGFloat(element.x + element.width / 2) + dragOffset.width
    }
    private var displayCenterY: CGFloat {
        CGFloat(element.y + element.height / 2) + dragOffset.height
    }

    var body: some View {
        // Base comum: conteúdo dimensionado, rotacionado e posicionado pelo centro.
        // Tocar num não-selecionado seleciona; o toque em espaço vazio é do integrador.
        let base = framedContent
            .rotationEffect(.radians(element.rotation)) // 0 = sem rotação (respeitado no display)
            .position(x: displayCenterX, y: displayCenterY)
            .onTapGesture { if !isSelected { onSelect() } }

        // Move/pinça só valem para o elemento SELECIONADO.
        if isSelected {
            base.gesture(combinedGesture)
        } else {
            base
        }
    }

    // MARK: - Conteúdo (imagem ou placeholder) já dimensionado

    @ViewBuilder
    private var framedContent: some View {
        Group {
            if element.kind == .text {
                textContent
            } else if let uiImage = loadedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .frame(width: displayWidth, height: displayHeight)
            } else {
                // Falha ao carregar o arquivo do asset: placeholder cinza-claro do mesmo tamanho.
                Rectangle()
                    .fill(Color(white: 0.9))
                    .frame(width: displayWidth, height: displayHeight)
            }
        }
        .overlay { if isSelected { selectionBorder } }
        .overlay(alignment: .topLeading) { if isSelected { deleteButton } }
        .overlay(alignment: .topTrailing) {
            if isSelected && element.kind == .text { editButton }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected && element.kind == .image { removeBGButton }
        }
    }

    /// Botão "tirar fundo" (só em imagens selecionadas), canto inferior-direito.
    private var removeBGButton: some View {
        Button(action: onRemoveBackground) {
            Image(systemName: "scissors")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(7)
                .background(.blue, in: Circle())
        }
        .buttonStyle(.plain)
        .offset(x: 10, y: 10)
    }

    /// Botão de editar o texto (só aparece em caixas de texto selecionadas), canto superior-direito.
    private var editButton: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .blue)
        }
        .buttonStyle(.plain)
        .offset(x: 10, y: -10)
    }

    /// Conteúdo de uma caixa de TEXTO. Mostra um texto-guia quando vazia. O fundo quase
    /// transparente garante que a caixa inteira (não só as letras) receba toque/arraste.
    private var textContent: some View {
        Text(hasText ? element.text! : "Toque em ✎ para editar")
            .font(.system(size: displayFontSize))
            .foregroundColor(hasText ? (PageElementColor.from(hex: element.colorHex) ?? .primary)
                                     : .secondary)
            .frame(width: displayWidth, height: displayHeight, alignment: .topLeading)
            .background(Color.white.opacity(0.001))
            .clipped()
    }

    private var hasText: Bool { (element.text?.isEmpty == false) }

    /// Tamanho de fonte exibido = tamanho salvo × pinça em curso (feedback ao vivo do zoom).
    private var displayFontSize: CGFloat {
        CGFloat(element.fontSize ?? 20) * pinchScale
    }

    /// Carrega a imagem direto do arquivo do asset (sem cópia extra em memória).
    private var loadedImage: UIImage? {
        UIImage(contentsOfFile: store.assetFileURL(id: element.assetID).path)
    }

    // MARK: - Adornos de seleção

    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.blue, lineWidth: 1.5)
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
        }
        .buttonStyle(.plain)
        // Puxa o botão para fora do canto superior-esquerdo do quadro.
        .offset(x: -10, y: -10)
    }

    // MARK: - Gestos (move + pinça, simultâneos)

    /// Combina arraste e pinça para poderem acontecer ao mesmo tempo sem um "roubar" o outro.
    private var combinedGesture: some Gesture {
        dragGesture.simultaneously(with: magnificationGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let newX = element.x + Double(value.translation.width)
                let newY = element.y + Double(value.translation.height)
                onMove(newX, newY)
                dragOffset = .zero
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let (newWidth, newHeight) = clampedSize(scaling: value)
                onResize(newWidth, newHeight)
            }
    }

    /// Multiplica largura/altura pelo fator da pinça, PRESERVANDO a proporção e mantendo
    /// os dois lados dentro de [minSide, maxSide]. Ajustamos o próprio fator (e não cada
    /// lado isolado) justamente para não distorcer a imagem.
    private func clampedSize(scaling factor: CGFloat) -> (Double, Double) {
        var scale = Double(factor)
        let smallestSide = min(element.width, element.height)
        let largestSide = max(element.width, element.height)

        // Não deixa o menor lado ficar abaixo do mínimo...
        if smallestSide * scale < Self.minSide {
            scale = Self.minSide / smallestSide
        }
        // ...nem o maior lado passar do máximo.
        if largestSide * scale > Self.maxSide {
            scale = Self.maxSide / largestSide
        }
        return (element.width * scale, element.height * scale)
    }
}

// MARK: - Cor a partir de hex (fileprivate para não colidir com helpers de outros arquivos)

/// Converte "#RRGGBB"/"RRGGBB" em `Color`. Retorna nil se não parsear (a caixa de texto
/// cai então na cor padrão). Mantido fileprivate para evitar duplicar um símbolo global.
private enum PageElementColor {
    static func from(hex raw: String?) -> Color? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}
