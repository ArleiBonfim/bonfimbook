import SwiftUI
import PencilKit
import CadernoCore

/// Um caderno ABERTO: a página atual (papel + canvas transparente por cima) ocupa o
/// centro, com uma barra superior (voltar, papel, entrada, backup) e uma barra inferior
/// de navegação entre páginas (anterior/próxima, adicionar, apagar, miniaturas).
///
/// Recebe um `NotebookStore` já aberto (a `LibraryView` cria/abre e navega pra cá) e o
/// `BackupManager` global do ambiente. O salvamento do traço é responsabilidade do
/// `PKCanvasRepresentable` (debounce + backup); aqui só orquestramos páginas/template.
struct NotebookView: View {
    let store: NotebookStore

    @EnvironmentObject private var backup: BackupManager
    @Environment(\.dismiss) private var dismiss

    // Páginas na ordem do manifest e índice da página em foco.
    @State private var pages: [PageMeta] = []
    @State private var currentIndex: Int = 0
    // Template da página atual — dirige o `PaperBackgroundView` e atualiza na hora ao trocar.
    @State private var currentTemplate: PaperTemplate = .ruled

    // Política de entrada do canvas (mesma escolha oferecida na antiga RootView).
    @State private var drawingPolicy: PKCanvasViewDrawingPolicy = .pencilOnly

    // Apresentações modais / confirmações.
    @State private var showThumbnails = false
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            pageArea
            Divider()
            bottomBar
        }
        .navigationBarHidden(true)
        .onAppear(perform: reload)
        .sheet(isPresented: $showThumbnails) {
            PageThumbnailsView(store: store) { index in
                currentIndex = index
                syncTemplate()
            }
        }
        .alert("Apagar esta página?", isPresented: $showDeleteConfirm) {
            Button("Cancelar", role: .cancel) {}
            Button("Apagar", role: .destructive) { deleteCurrentPage() }
        } message: {
            Text("A página vai para a lixeira do caderno e pode ser restaurada depois.")
        }
    }

    // MARK: - Página atual

    /// A página em foco, ou `nil` se (por algum motivo) não há páginas.
    private var currentPage: PageMeta? {
        pages.indices.contains(currentIndex) ? pages[currentIndex] : nil
    }

    // MARK: - Área central (papel + canvas)

    private var pageArea: some View {
        ZStack {
            // O papel é sempre claro e independe de dark mode (ver PaperBackgroundView).
            PaperBackgroundView(template: currentTemplate)

            if let page = currentPage {
                PKCanvasRepresentable(
                    store: store,
                    backup: backup,
                    pageID: page.id,
                    drawingPolicy: $drawingPolicy
                )
                // Recria o canvas ao trocar de página: garante a carga inicial correta
                // e descarta qualquer debounce pendente da página anterior.
                .id(page.id)
            } else {
                Text("Caderno vazio")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Barra superior

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Label("Biblioteca", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("Voltar para a biblioteca")

            Spacer()

            paperMenu

            Picker("Entrada", selection: $drawingPolicy) {
                Text("Automático").tag(PKCanvasViewDrawingPolicy.default)
                Text("Só caneta").tag(PKCanvasViewDrawingPolicy.pencilOnly)
                Text("Qualquer toque").tag(PKCanvasViewDrawingPolicy.anyInput)
            }
            .pickerStyle(.menu)
            .labelsHidden()

            BackupStatusView()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Menu "Papel": lista todos os templates e troca o da página atual na hora.
    private var paperMenu: some View {
        Menu {
            ForEach(PaperTemplate.allCases, id: \.self) { template in
                Button {
                    changeTemplate(to: template)
                } label: {
                    if template == currentTemplate {
                        Label(template.displayName, systemImage: "checkmark")
                    } else {
                        Text(template.displayName)
                    }
                }
            }
        } label: {
            Label("Papel", systemImage: "doc.plaintext")
        }
        .accessibilityLabel("Estilo de papel")
    }

    // MARK: - Barra inferior

    private var bottomBar: some View {
        HStack(spacing: 20) {
            Button {
                goToPage(currentIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .imageScale(.large)
            }
            .disabled(currentIndex <= 0)
            .accessibilityLabel("Página anterior")

            Text("Pág. \(pages.isEmpty ? 0 : currentIndex + 1) de \(pages.count)")
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 96)

            Button {
                goToPage(currentIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .imageScale(.large)
            }
            .disabled(currentIndex >= pages.count - 1)
            .accessibilityLabel("Próxima página")

            Spacer()

            Button {
                addPage()
            } label: {
                Image(systemName: "plus")
                    .imageScale(.large)
            }
            .accessibilityLabel("Adicionar página")

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .imageScale(.large)
            }
            // Um caderno mantém ao menos uma página.
            .disabled(pages.count <= 1)
            .accessibilityLabel("Apagar página atual")

            Button {
                showThumbnails = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .imageScale(.large)
            }
            .accessibilityLabel("Miniaturas das páginas")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Ações

    /// (Re)carrega as páginas do disco, corrige o índice e sincroniza o template exibido.
    private func reload() {
        pages = (try? store.pages()) ?? []
        clampIndex()
        syncTemplate()
    }

    /// Garante que `currentIndex` aponta para uma página válida.
    private func clampIndex() {
        if pages.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(max(0, currentIndex), pages.count - 1)
        }
    }

    /// Deriva o `currentTemplate` da página em foco (fallback `.ruled` se desconhecido).
    private func syncTemplate() {
        if let page = currentPage {
            currentTemplate = PaperTemplate(rawValue: page.template) ?? .ruled
        }
    }

    private func goToPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        currentIndex = index
        syncTemplate()
    }

    /// Acrescenta uma página nova usando o template atual como padrão e navega até ela.
    private func addPage() {
        _ = try? store.addPage(template: currentTemplate.rawValue)
        reload()
        if !pages.isEmpty {
            currentIndex = pages.count - 1
            syncTemplate()
        }
    }

    /// Apaga (move para a lixeira) a página em foco e reposiciona o índice.
    private func deleteCurrentPage() {
        guard let page = currentPage else { return }
        try? store.deletePage(id: page.id)
        reload()
    }

    /// Troca o template da página atual: atualiza o fundo na hora e persiste no store.
    private func changeTemplate(to template: PaperTemplate) {
        guard let page = currentPage else { return }
        // Atualiza o papel imediatamente para o usuário ver a mudança sem esperar o disco.
        currentTemplate = template
        try? store.setTemplate(template.rawValue, pageID: page.id)
        reload()
    }
}
