import SwiftUI
import PencilKit
import CadernoCore

/// Grade de miniaturas das páginas de um caderno. Cada célula mostra o PAPEL do template
/// com o traço renderizado por cima (imagem do `PKDrawing`); se algo faltar (template
/// desconhecido), cai para um cartão simples com número, nome do template e data.
///
/// Tocar numa miniatura chama `onSelect(índice)` e fecha a folha.
struct PageThumbnailsView: View {
    let store: NotebookStore
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pages: [PageMeta] = []

    // Proporção de papel (retrato) e largura mínima da célula na grade.
    private let cellWidth: CGFloat = 150
    private let paperAspect: CGFloat = 4.0 / 3.0   // altura / largura

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth), spacing: 16)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            onSelect(index)
                            dismiss()
                        } label: {
                            cell(for: page, number: index + 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Páginas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
            .onAppear {
                pages = (try? store.pages()) ?? []
            }
        }
    }

    // MARK: - Célula

    @ViewBuilder
    private func cell(for page: PageMeta, number: Int) -> some View {
        VStack(spacing: 6) {
            thumbnail(for: page, number: number)
                .frame(width: cellWidth, height: cellWidth * paperAspect)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(.separator), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)

            Text("Pág. \(number)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Miniatura visual: papel do template + imagem do traço por cima.
    /// Se o template for desconhecido, mostra o cartão de fallback.
    @ViewBuilder
    private func thumbnail(for page: PageMeta, number: Int) -> some View {
        if let template = PaperTemplate(rawValue: page.template) {
            ZStack {
                PaperBackgroundView(template: template)
                if let image = drawingImage(for: page) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                }
            }
        } else {
            fallbackCard(for: page, number: number)
        }
    }

    /// Cartão simples quando não dá para renderizar o papel/traço.
    private func fallbackCard(for page: PageMeta, number: Int) -> some View {
        VStack(spacing: 6) {
            Text("\(number)")
                .font(.largeTitle.weight(.bold))
            Text(templateName(page.template))
                .font(.caption)
            Text(Self.dateFormatter.string(from: page.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Helpers

    /// Renderiza o traço da página em `UIImage`, ou `nil` se não há desenho legível/visível.
    private func drawingImage(for page: PageMeta) -> UIImage? {
        // `try?` sobre `readDrawing` (que devolve `Data?`) já entrega `Data?`: um `if let` basta.
        guard let data = try? store.readDrawing(pageID: page.id),
              let drawing = try? PKDrawing(data: data) else {
            return nil
        }
        let bounds = drawing.bounds
        // Desenho vazio (sem traço) tem bounds nulo — nada a sobrepor.
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return drawing.image(from: bounds, scale: UIScreen.main.scale)
    }

    private func templateName(_ raw: String) -> String {
        PaperTemplate(rawValue: raw)?.displayName ?? raw
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
