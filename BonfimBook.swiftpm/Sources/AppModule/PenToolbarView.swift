import SwiftUI
import PencilKit

/// Barra FINA de canetas no topo da página — a alternativa discreta à paleta flutuante da
/// Apple. Usa exatamente as mesmas canetas do PencilKit, num filete horizontal, sempre no
/// mesmo lugar. Além das canetas básicas, traz um menu de canetas extras (tinteiro,
/// monolinha, giz, aquarela), 5 espessuras, cores rápidas e um menu de atalhos para as
/// funções mais usadas (caixa de texto, imagem, anteparo, melhorar traço, gerar imagem).
///
/// Todo o estado (caneta/cor/espessura) mora no `CanvasController`; as ações de conteúdo
/// chegam por closures do `NotebookView`. O corpo é quebrado em funções pequenas para evitar
/// o erro "expressão complexa demais" do compilador do iPad.
struct PenToolbarView: View {
    @ObservedObject var controller: CanvasController

    // Atalhos para as funções mais úteis (vêm do NotebookView).
    var onInsertText: () -> Void
    var onInsertImage: () -> Void
    var onPasteImage: () -> Void
    var onAddCover: () -> Void
    var onSmooth: () -> Void
    var onGenerateImage: () -> Void

    /// Paleta de cores rápidas da barra (as mais usadas). Qualquer outra cor sai no seletor.
    private static let quickColors: [Color] = [
        .black, .blue, .red, .green, .orange, .purple
    ]

    /// Espessuras rápidas: de bem fina a bem grossa.
    private static let widths: [CGFloat] = [1, 3, 6, 10, 16]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                penButtons
                extraPensMenu
                thinDivider
                colorButtons
                customColorButton
                thinDivider
                widthButtons
                thinDivider
                actionsMenu
                fullPaletteButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }

    // MARK: - Grupos

    private var penButtons: some View {
        HStack(spacing: 8) {
            penButton(.pen, symbol: "pencil.tip", label: "Caneta")
            penButton(.marker, symbol: "highlighter", label: "Marca-texto")
            penButton(.pencil, symbol: "pencil", label: "Lápis")
            penButton(.eraser, symbol: "eraser", label: "Borracha")
            penButton(.lasso, symbol: "lasso", label: "Selecionar")
        }
    }

    /// Menu com as canetas extras (estilos menos comuns). Fica destacado quando uma delas
    /// está ativa.
    private var extraPensMenu: some View {
        let extras: [PenKind] = [.fountainPen, .monoline, .crayon, .watercolor]
        let active = extras.contains(controller.toolKind)
        return Menu {
            inkMenuItem(.fountainPen, "Caneta tinteiro", "pencil.and.outline")
            inkMenuItem(.monoline, "Monolinha", "line.diagonal")
            inkMenuItem(.crayon, "Giz de cera", "scribble.variable")
            inkMenuItem(.watercolor, "Aquarela", "drop")
        } label: {
            Image(systemName: "paintbrush.pointed")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 30)
                .background(active ? Color.accentColor.opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(active ? Color.accentColor : .primary)
        }
        .accessibilityLabel("Mais canetas")
    }

    private func inkMenuItem(_ kind: PenKind, _ title: String, _ symbol: String) -> some View {
        Button {
            controller.selectInk(kind)
        } label: {
            if controller.toolKind == kind {
                Label("\(title) ✓", systemImage: symbol)
            } else {
                Label(title, systemImage: symbol)
            }
        }
    }

    private var colorButtons: some View {
        HStack(spacing: 8) {
            ForEach(Self.quickColors, id: \.self) { color in
                colorSwatch(color)
            }
        }
    }

    private var widthButtons: some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.widths.enumerated()), id: \.offset) { pair in
                widthButton(pair.element, index: pair.offset)
            }
        }
    }

    /// Menu de atalhos para as funções de conteúdo mais usadas.
    private var actionsMenu: some View {
        Menu {
            Button { onInsertText() } label: { Label("Caixa de texto", systemImage: "textbox") }
            Button { onInsertImage() } label: { Label("Imagem da galeria", systemImage: "photo") }
            Button { onPasteImage() } label: { Label("Colar imagem", systemImage: "doc.on.clipboard") }
            Button { onAddCover() } label: { Label("Anteparo (estudo)", systemImage: "rectangle.slash") }
            Divider()
            Button { onSmooth() } label: { Label("Melhorar traço", systemImage: "wand.and.stars") }
            Button { onGenerateImage() } label: { Label("Gerar imagem", systemImage: "sparkles") }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 30)
        }
        .accessibilityLabel("Inserir e ações")
    }

    // MARK: - Botões individuais

    private func penButton(_ kind: PenKind, symbol: String, label: String) -> some View {
        let active = controller.toolKind == kind
        return Button {
            controller.selectInk(kind)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 30)
                .background(active ? Color.accentColor.opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(active ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func colorSwatch(_ color: Color) -> some View {
        let active = controller.inkColor == color
                     && controller.toolKind != .eraser
                     && controller.toolKind != .lasso
        return Button {
            controller.selectColor(color)
        } label: {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().stroke(active ? Color.accentColor : Color.secondary.opacity(0.4),
                                    lineWidth: active ? 3 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cor")
    }

    /// Seletor de QUALQUER cor (roda de cores do sistema), compacto.
    private var customColorButton: some View {
        ColorPicker("Cor personalizada",
                    selection: Binding(get: { controller.inkColor },
                                       set: { controller.selectColor($0) }),
                    supportsOpacity: false)
            .labelsHidden()
            .frame(width: 26, height: 26)
    }

    private func widthButton(_ width: CGFloat, index: Int) -> some View {
        let active = controller.lineWidth == width
                     && controller.toolKind != .eraser
                     && controller.toolKind != .lasso
        // Ponto que cresce com a espessura, para leitura visual rápida (limitado p/ caber).
        let dot = min(5 + CGFloat(index) * 4, 22)
        return Button {
            controller.selectWidth(width)
        } label: {
            Circle()
                .fill(active ? Color.accentColor : Color.primary)
                .frame(width: dot, height: dot)
                .frame(width: 34, height: 30)
                .background(active ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Espessura")
    }

    /// Abre a paleta COMPLETA da Apple (régua, mais canetas, opacidade). A barra fina some
    /// enquanto ela estiver ativa; o botão na barra de cima traz de volta.
    private var fullPaletteButton: some View {
        Button {
            controller.useSystemPicker = true
            controller.syncPickerVisibility()
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Abrir paleta completa da Apple")
    }

    // MARK: - Enfeites

    private var thinDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 1, height: 24)
    }
}
