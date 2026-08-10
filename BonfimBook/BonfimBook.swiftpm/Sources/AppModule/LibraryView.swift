import SwiftUI
import CadernoCore

/// Tela inicial do app: a biblioteca de cadernos.
///
/// Lista os pacotes `.caderno` do diretório padrão (via `NotebookLibrary.list`), mostra
/// cada um como uma "capa" colorida com título, contagem de páginas e data, e permite
/// criar um caderno novo ou apagar (mover para a lixeira) os existentes.
///
/// Ao tocar num caderno, abre o `NotebookStore` correspondente e navega para a
/// `NotebookView` (tela de outro agente) que recebe o store já aberto.
struct LibraryView: View {

    // O BackupManager é global, injetado pelo `CadernoApp` no ambiente.
    @EnvironmentObject private var backup: BackupManager

    /// Cadernos atualmente exibidos (ordenados por `updatedAt` desc pelo Core).
    @State private var notebooks: [NotebookRef] = []

    /// Caminho de navegação por URL do pacote. Usamos URL (Hashable nativo) para não
    /// depender de conformância `Hashable` do `NotebookRef` (o contrato só exige `Equatable`).
    @State private var path: [URL] = []

    /// Caderno aguardando confirmação de exclusão (nil = nenhum).
    @State private var pendingDelete: NotebookRef?

    /// Controla a folha do diagnóstico da caneta.
    @State private var showDiagnostics = false

    /// Mensagem de erro amigável (nil = sem erro). Mostrada num alerta simples.
    @State private var errorMessage: String?

    // Grade adaptativa: capas de ~150pt, quebrando conforme a largura disponível.
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if notebooks.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("BonfimBook")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .navigationDestination(for: URL.self) { url in
                notebookDestination(for: url)
            }
            .sheet(isPresented: $showDiagnostics) {
                PenDiagnosticView()
            }
            .confirmationDialog(
                "Apagar este caderno?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { ref in
                Button("Apagar \u{201C}\(ref.title)\u{201D}", role: .destructive) {
                    delete(ref)
                }
                Button("Cancelar", role: .cancel) { pendingDelete = nil }
            } message: { ref in
                Text("O caderno \u{201C}\(ref.title)\u{201D} vai para a lixeira. Você poderá recuperá-lo depois.")
            }
            .alert(
                "Algo deu errado",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { msg in
                Text(msg)
            }
            // Recarrega ao aparecer (inclui a volta de um caderno, refletindo mudanças).
            .onAppear(perform: reload)
        }
    }

    // MARK: - Barra superior

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            BackupStatusView()
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button(action: createNotebook) {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Novo caderno")

            Button {
                showDiagnostics = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Diagnóstico da caneta")
        }
    }

    // MARK: - Grade de cadernos

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(notebooks, id: \.url) { ref in
                    Button {
                        open(ref.url)
                    } label: {
                        NotebookCoverCell(ref: ref)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDelete = ref
                        } label: {
                            Label("Apagar", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Estado vazio

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.closed")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Crie seu primeiro caderno")
                .font(.title2.weight(.semibold))
            Text("Toque no botão abaixo para começar a escrever à mão.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: createNotebook) {
                Label("Novo caderno", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Destino de navegação

    /// Abre o store da URL e entrega para a `NotebookView`. Se falhar, mostra um aviso
    /// e um botão para voltar (em vez de derrubar o app).
    @ViewBuilder
    private func notebookDestination(for url: URL) -> some View {
        if let store = try? NotebookStore.open(packageURL: url) {
            NotebookView(store: store)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Não foi possível abrir este caderno.")
                    .font(.headline)
                Button("Voltar à biblioteca") {
                    if !path.isEmpty { path.removeLast() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
        }
    }

    // MARK: - Ações

    /// Lê o diretório padrão e recarrega a lista. Tolerante: em falha, esvazia sem quebrar.
    private func reload() {
        guard let dir = try? NotebookLibrary.defaultDirectory() else {
            notebooks = []
            return
        }
        notebooks = (try? NotebookLibrary.list(in: dir)) ?? []
    }

    /// Cria um caderno novo com título "Caderno N" e cor sorteada, depois o abre.
    private func createNotebook() {
        guard let dir = try? NotebookLibrary.defaultDirectory() else {
            errorMessage = "Não foi possível localizar a pasta de cadernos."
            return
        }

        let title = nextTitle()
        let hex = Self.coverPalette.randomElement() ?? Self.defaultCoverHex

        do {
            let store = try NotebookLibrary.create(in: dir, title: title, coverColorHex: hex)
            reload()
            // Navega para o caderno recém-criado (o destino reabre o pacote pela URL).
            open(store.packageURL)
        } catch {
            errorMessage = "Não foi possível criar o caderno: \(error.localizedDescription)"
        }
    }

    private func open(_ url: URL) {
        path.append(url)
    }

    private func delete(_ ref: NotebookRef) {
        pendingDelete = nil
        do {
            try NotebookLibrary.moveToTrash(ref.url)
            reload()
        } catch {
            errorMessage = "Não foi possível apagar o caderno: \(error.localizedDescription)"
        }
    }

    /// Próximo número livre para "Caderno N", evitando colidir com títulos já existentes.
    private func nextTitle() -> String {
        let existing = Set(notebooks.map { $0.title })
        var n = notebooks.count + 1
        while existing.contains("Caderno \(n)") {
            n += 1
        }
        return "Caderno \(n)"
    }

    // MARK: - Paleta de capas (hex fixos)

    static let defaultCoverHex = "#4E86C7"
    static let coverPalette: [String] = [
        "#E8705A", // coral
        "#F2B134", // âmbar
        "#5AAE7A", // verde
        "#4E86C7", // azul
        "#8E6FC0", // roxo
        "#D96FA0"  // rosa
    ]
}

// MARK: - Célula de capa

/// Uma "capa" de caderno: retângulo colorido com o título, seguido de contagem de
/// páginas e data da última modificação.
private struct NotebookCoverCell: View {
    let ref: NotebookRef

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
            Text(ref.title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text("\(ref.pageCount) \(ref.pageCount == 1 ? "página" : "páginas") · \(Self.dateFormatter.string(from: ref.updatedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var cover: some View {
        let color = LibraryColor.from(hex: ref.coverColorHex) ?? LibraryColor.from(hex: LibraryView.defaultCoverHex) ?? .blue
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(color)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                // "Lombada": uma faixa mais escura à esquerda para dar cara de livro.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.12))
                    .frame(width: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topLeading) {
                Text(ref.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .padding(14)
                    .padding(.leading, 6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Conversão de cor (fileprivate para não colidir com outros arquivos)

/// Utilitário local de hex → Color. Mantido `enum` fileprivate para evitar duplicar um
/// símbolo `Color(hex:)` que outro arquivo do módulo possa definir.
private enum LibraryColor {
    /// Aceita "#RRGGBB", "RRGGBB", "#RGB" ou "RGB". Retorna nil se não parsear.
    static func from(hex raw: String?) -> Color? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if s.hasPrefix("#") { s.removeFirst() }

        // Expande forma curta "RGB" -> "RRGGBB".
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}
