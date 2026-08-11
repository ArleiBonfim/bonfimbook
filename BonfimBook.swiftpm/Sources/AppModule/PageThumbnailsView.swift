import SwiftUI
import PencilKit
import CadernoCore

/// Grade de miniaturas das páginas de um caderno. Cada célula mostra o FUNDO da página
/// (documento importado, se houver, senão o papel do template) com o traço renderizado por
/// cima. Segurar uma miniatura abre um menu com: favoritar, mover (esquerda/direita),
/// duplicar e apagar. Um filtro no topo mostra só as favoritas.
///
/// Tocar numa miniatura chama `onSelect(índiceReal)` (índice na ordem completa) e fecha a folha.
struct PageThumbnailsView: View {
    let store: NotebookStore
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pages: [PageMeta] = []
    @State private var favoritesOnly = false

    // Proporção de papel (retrato) e largura mínima da célula na grade.
    private let cellWidth: CGFloat = 150
    private let paperAspect: CGFloat = 4.0 / 3.0   // altura / largura

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth), spacing: 16)]
    }

    /// Páginas exibidas conforme o filtro (mantendo a ordem real).
    private var displayedPages: [PageMeta] {
        favoritesOnly ? pages.filter { $0.favorite == true } : pages
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(displayedPages, id: \.id) { page in
                        let number = realIndex(of: page).map { $0 + 1 } ?? 0
                        Button {
                            if let idx = realIndex(of: page) {
                                onSelect(idx)
                                dismiss()
                            }
                        } label: {
                            cell(for: page, number: number)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: page) }
                    }
                }
                .padding(16)
            }
            .navigationTitle(favoritesOnly ? "Favoritas" : "Páginas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        favoritesOnly.toggle()
                    } label: {
                        Image(systemName: favoritesOnly ? "star.fill" : "star")
                    }
                    .accessibilityLabel(favoritesOnly ? "Mostrar todas" : "Mostrar só favoritas")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
            .onAppear(perform: reload)
        }
    }

    // MARK: - Menu de contexto (segurar a miniatura)

    @ViewBuilder
    private func contextMenu(for page: PageMeta) -> some View {
        let isFav = page.favorite == true
        Button {
            try? store.setFavorite(!isFav, pageID: page.id)
            reload()
        } label: {
            Label(isFav ? "Desfavoritar" : "Favoritar",
                  systemImage: isFav ? "star.slash" : "star")
        }

        if let idx = realIndex(of: page) {
            Button {
                try? store.movePage(id: page.id, toIndex: idx - 1)
                reload()
            } label: {
                Label("Mover para a esquerda", systemImage: "arrow.left")
            }
            .disabled(idx <= 0)

            Button {
                try? store.movePage(id: page.id, toIndex: idx + 1)
                reload()
            } label: {
                Label("Mover para a direita", systemImage: "arrow.right")
            }
            .disabled(idx >= pages.count - 1)
        }

        Button {
            _ = try? store.duplicatePage(id: page.id)
            reload()
        } label: {
            Label("Duplicar", systemImage: "plus.square.on.square")
        }

        Button(role: .destructive) {
            // Um caderno mantém ao menos uma página.
            if pages.count > 1 {
                try? store.deletePage(id: page.id)
                reload()
            }
        } label: {
            Label("Apagar", systemImage: "trash")
        }
        .disabled(pages.count <= 1)
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
                // Estrela no canto quando favorita.
                .overlay(alignment: .topTrailing) {
                    if page.favorite == true {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(.black.opacity(0.35), in: Circle())
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)

            Text("Pág. \(number)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Miniatura visual: fundo (documento OU papel) + imagem do traço por cima.
    @ViewBuilder
    private func thumbnail(for page: PageMeta, number: Int) -> some View {
        if let background = page.background {
            ZStack {
                PageBackgroundContentView(store: store, background: background)
                drawingOverlay(for: page)
            }
        } else if let template = PaperTemplate(rawValue: page.template) {
            ZStack {
                PaperBackgroundView(template: template)
                drawingOverlay(for: page)
            }
        } else {
            fallbackCard(for: page, number: number)
        }
    }

    /// Imagem do traço (se houver), sobreposta ao fundo.
    @ViewBuilder
    private func drawingOverlay(for page: PageMeta) -> some View {
        if let image = drawingImage(for: page) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(4)
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

    private func reload() {
        pages = (try? store.pages()) ?? []
    }

    /// Índice da página na ordem COMPLETA (para onSelect/mover, mesmo com filtro ativo).
    private func realIndex(of page: PageMeta) -> Int? {
        pages.firstIndex { $0.id == page.id }
    }

    /// Renderiza o traço da página em `UIImage`, ou `nil` se não há desenho legível/visível.
    private func drawingImage(for page: PageMeta) -> UIImage? {
        guard let data = try? store.readDrawing(pageID: page.id),
              let drawing = try? PKDrawing(data: data) else {
            return nil
        }
        let bounds = drawing.bounds
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
