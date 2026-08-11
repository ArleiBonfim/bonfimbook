import SwiftUI
import UIKit
import PencilKit
import CadernoCore

/// Um caderno ABERTO: a página atual (papel + imagens + canvas transparente por cima)
/// ocupa o centro, com uma barra superior (voltar, desfazer/refazer, título, papel, foto,
/// modo-imagem, mais ações, backup) e uma barra inferior de navegação entre páginas.
///
/// Recebe um `NotebookStore` já aberto (a `LibraryView` cria/abre e navega pra cá) e o
/// `BackupManager` global do ambiente. O salvamento do TRAÇO é do `PKCanvasRepresentable`
/// (debounce + backup, intocado); aqui orquestramos páginas, papel, imagens e exportação.
struct NotebookView: View {
    let store: NotebookStore

    @EnvironmentObject private var backup: BackupManager
    @Environment(\.dismiss) private var dismiss

    // Controlador de desfazer/refazer (e ancoragem do zoom) do canvas atual.
    @StateObject private var canvasController = CanvasController()

    // Páginas na ordem do manifest e índice da página em foco.
    @State private var pages: [PageMeta] = []
    @State private var currentIndex: Int = 0
    // Template da página atual — dirige o `PaperBackgroundView` e atualiza na hora ao trocar.
    @State private var currentTemplate: PaperTemplate = .defaultTemplate
    // Título do caderno (para exibir/renomear); vem do manifest.
    @State private var title: String = ""

    // Imagens da página atual (fonte da verdade em memória enquanto a página está aberta).
    @State private var elements: [PageElement] = []
    @State private var selectedElementID: String?
    // Modo "mexer nas imagens": quando ligado, o dedo move/redimensiona imagens em vez de
    // desenhar (o canvas para de receber toques; a camada de imagens passa a recebê-los).
    @State private var imageEditMode = false
    // Tamanho real da área de página na tela — usado para centralizar imagens novas.
    @State private var pageSize: CGSize = .zero

    // Política de entrada do canvas (só caneta, qualquer toque, automático).
    @State private var drawingPolicy: PKCanvasViewDrawingPolicy = .pencilOnly

    // Apresentações modais / confirmações.
    @State private var showThumbnails = false
    @State private var showDeleteConfirm = false
    @State private var showPhotoPicker = false
    @State private var showPDFImport = false
    @State private var showScanner = false
    @State private var showRename = false
    @State private var renameText = ""
    // Edição de caixa de texto.
    @State private var editingTextElementID: String?
    @State private var editingText = ""
    @State private var showTextEditor = false
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    // Dimensões lógicas de referência quando ainda não sabemos o tamanho real da tela.
    private static let fallbackSize = CGSize(width: 768, height: 1024)

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
        .sheet(isPresented: $showThumbnails, onDismiss: { reload() }) {
            PageThumbnailsView(store: store) { index in
                goToPage(index)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(
                onPick: { data, ext in
                    showPhotoPicker = false
                    insertImage(data: data, ext: ext)
                },
                onCancel: { showPhotoPicker = false }
            )
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showPDFImport) {
            PDFDocumentPicker(
                onPick: { data in
                    showPDFImport = false
                    importPDF(data: data)
                },
                onCancel: { showPDFImport = false }
            )
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner(
                onFinish: { datas in
                    showScanner = false
                    scanDocuments(datas)
                },
                onCancel: { showScanner = false },
                onError: { error in
                    showScanner = false
                    errorMessage = "A digitalização falhou: \(error.localizedDescription)"
                }
            )
            .ignoresSafeArea()
        }
        .alert("Renomear caderno", isPresented: $showRename) {
            TextField("Nome do caderno", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { commitRename() }
        } message: {
            Text("Escolha um novo nome para este caderno.")
        }
        .alert("Editar texto", isPresented: $showTextEditor) {
            TextField("Texto", text: $editingText)
            Button("Cancelar", role: .cancel) { editingTextElementID = nil }
            Button("Salvar") { commitTextEdit() }
        } message: {
            Text("Digite o texto da caixa.")
        }
        .alert("Apagar esta página?", isPresented: $showDeleteConfirm) {
            Button("Cancelar", role: .cancel) {}
            Button("Apagar", role: .destructive) { deleteCurrentPage() }
        } message: {
            Text("A página vai para a lixeira do caderno e pode ser restaurada depois.")
        }
        .alert(
            "Algo deu errado",
            isPresented: Binding(get: { errorMessage != nil },
                                 set: { if !$0 { errorMessage = nil } }),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Página atual

    /// A página em foco, ou `nil` se (por algum motivo) não há páginas.
    private var currentPage: PageMeta? {
        pages.indices.contains(currentIndex) ? pages[currentIndex] : nil
    }

    /// Tamanho a usar para posicionar imagens (real da tela, ou o de referência).
    private var effectiveSize: CGSize {
        pageSize.width > 0 && pageSize.height > 0 ? pageSize : Self.fallbackSize
    }

    // MARK: - Área central (papel + imagens + canvas)

    private var pageArea: some View {
        GeometryReader { geo in
            ZStack {
                // Fundo: documento importado (PDF/imagem escaneada) OU papel do template.
                // O papel é sempre claro e independe de dark mode (ver PaperBackgroundView).
                if let page = currentPage, let bg = page.background {
                    PageBackgroundContentView(store: store, background: bg)
                } else {
                    PaperBackgroundView(template: currentTemplate)
                }

                if let page = currentPage {
                    // Camada invisível para "desselecionar" ao tocar em espaço vazio,
                    // ativa só no modo de edição de imagem (fica sob as imagens).
                    if imageEditMode {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { selectedElementID = nil }
                    }

                    // Imagens: abaixo do canvas (o traço fica sempre por cima). Só recebem
                    // toque no modo edição.
                    PageImageLayerView(
                        store: store,
                        elements: $elements,
                        selectedElementID: $selectedElementID,
                        onCommit: { newElements in persistElements(newElements) },
                        onEditText: { element in beginEditText(element) }
                    )
                    .allowsHitTesting(imageEditMode)

                    // Traço à mão: por cima. Só recebe toque FORA do modo edição.
                    PKCanvasRepresentable(
                        store: store,
                        backup: backup,
                        pageID: page.id,
                        drawingPolicy: $drawingPolicy,
                        controller: canvasController
                    )
                    .allowsHitTesting(!imageEditMode)
                    // Recria o canvas ao trocar de página: garante a carga inicial correta
                    // e descarta qualquer debounce pendente da página anterior.
                    .id(page.id)
                } else {
                    Text("Caderno vazio")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { pageSize = geo.size }
            .onChange(of: geo.size) { pageSize = $0 }
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
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Voltar para a biblioteca")

            // Desfazer / Refazer (delegados ao UndoManager nativo do canvas).
            Button {
                canvasController.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!canvasController.canUndo)
            .accessibilityLabel("Desfazer")

            Button {
                canvasController.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!canvasController.canRedo)
            .accessibilityLabel("Refazer")

            // Título do caderno — tocar para renomear.
            Button {
                renameText = title
                showRename = true
            } label: {
                Text(title.isEmpty ? "Caderno" : title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Renomear caderno")

            Spacer()

            paperMenu

            // Inserir imagem da galeria.
            Button {
                showPhotoPicker = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
            }
            .accessibilityLabel("Inserir imagem")

            // Modo "mexer nas imagens" (liga/desliga). Destacado quando ligado.
            Button {
                imageEditMode.toggle()
                if !imageEditMode { selectedElementID = nil }
            } label: {
                Image(systemName: imageEditMode ? "hand.point.up.left.fill" : "hand.point.up.left")
            }
            .tint(imageEditMode ? .accentColor : nil)
            .accessibilityLabel(imageEditMode ? "Sair do modo imagem" : "Mexer nas imagens")

            moreMenu

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
            Image(systemName: "doc.plaintext")
        }
        .accessibilityLabel("Estilo de papel")
    }

    /// Menu "Mais": exportar PDF, renomear e a política de entrada da caneta.
    private var moreMenu: some View {
        Menu {
            Button {
                showPDFImport = true
            } label: {
                Label("Importar PDF", systemImage: "doc.badge.plus")
            }

            Button {
                showScanner = true
            } label: {
                Label("Digitalizar documento", systemImage: "doc.viewfinder")
            }

            Button {
                pasteImage()
            } label: {
                Label("Colar imagem copiada", systemImage: "doc.on.clipboard")
            }

            Button {
                insertTextBox()
            } label: {
                Label("Inserir caixa de texto", systemImage: "textbox")
            }

            Divider()

            Button {
                exportPDF()
            } label: {
                Label("Exportar / compartilhar PDF", systemImage: "square.and.arrow.up")
            }

            Button {
                exportPageImage()
            } label: {
                Label("Exportar página como imagem", systemImage: "photo")
            }

            Button {
                renameText = title
                showRename = true
            } label: {
                Label("Renomear caderno", systemImage: "pencil")
            }

            Picker("Entrada", selection: $drawingPolicy) {
                Text("Automático").tag(PKCanvasViewDrawingPolicy.default)
                Text("Só caneta").tag(PKCanvasViewDrawingPolicy.pencilOnly)
                Text("Qualquer toque").tag(PKCanvasViewDrawingPolicy.anyInput)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Mais ações")
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

            Button {
                duplicateCurrentPage()
            } label: {
                Image(systemName: "plus.square.on.square")
                    .imageScale(.large)
            }
            .accessibilityLabel("Duplicar página")

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
                toggleFavoriteCurrent()
            } label: {
                Image(systemName: (currentPage?.favorite == true) ? "star.fill" : "star")
                    .imageScale(.large)
                    .foregroundStyle((currentPage?.favorite == true) ? .yellow : .primary)
            }
            .accessibilityLabel("Favoritar página")

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

    /// (Re)carrega páginas/título do disco, corrige o índice e sincroniza papel e imagens.
    private func reload() {
        pages = (try? store.pages()) ?? []
        title = (try? store.loadManifest().title) ?? ""
        clampIndex()
        syncTemplate()
        loadElements()
    }

    /// Garante que `currentIndex` aponta para uma página válida.
    private func clampIndex() {
        if pages.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(max(0, currentIndex), pages.count - 1)
        }
    }

    /// Deriva o `currentTemplate` da página em foco (fallback ao padrão se desconhecido).
    private func syncTemplate() {
        if let page = currentPage {
            currentTemplate = PaperTemplate(rawValue: page.template) ?? .defaultTemplate
        }
    }

    /// Carrega as imagens da página em foco e limpa a seleção.
    private func loadElements() {
        elements = currentPage?.elements ?? []
        selectedElementID = nil
    }

    private func goToPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        currentIndex = index
        syncTemplate()
        loadElements()
    }

    /// Acrescenta uma página nova usando o template atual como padrão e navega até ela.
    private func addPage() {
        _ = try? store.addPage(template: currentTemplate.rawValue)
        reload()
        if !pages.isEmpty {
            currentIndex = pages.count - 1
            syncTemplate()
            loadElements()
        }
    }

    /// Duplica a página atual (traço + imagens) e navega para a cópia (logo após).
    private func duplicateCurrentPage() {
        guard let page = currentPage else { return }
        do {
            let copy = try store.duplicatePage(id: page.id)
            reload()
            if let idx = pages.firstIndex(where: { $0.id == copy.id }) {
                currentIndex = idx
                syncTemplate()
                loadElements()
            }
        } catch {
            errorMessage = "Não foi possível duplicar a página: \(error.localizedDescription)"
        }
    }

    /// Apaga (move para a lixeira) a página em foco e reposiciona o índice.
    private func deleteCurrentPage() {
        guard let page = currentPage else { return }
        try? store.deletePage(id: page.id)
        reload()
    }

    /// Marca/desmarca a página atual como favorita.
    private func toggleFavoriteCurrent() {
        guard let page = currentPage else { return }
        let newValue = !(page.favorite == true)
        try? store.setFavorite(newValue, pageID: page.id)
        if pages.indices.contains(currentIndex) {
            pages[currentIndex].favorite = newValue ? true : nil
        }
    }

    /// Troca o template da página atual: atualiza o fundo na hora e persiste no store.
    private func changeTemplate(to template: PaperTemplate) {
        guard let page = currentPage else { return }
        currentTemplate = template
        try? store.setTemplate(template.rawValue, pageID: page.id)
        // Mantém a memória consistente sem reler tudo do disco.
        if pages.indices.contains(currentIndex) {
            pages[currentIndex].template = template.rawValue
        }
    }

    /// Salva o novo título (ignora vazio) e reflete na barra.
    private func commitRename() {
        try? store.setTitle(renameText)
        title = (try? store.loadManifest().title) ?? title
    }

    /// Persiste a lista de imagens da página atual e mantém a memória local consistente.
    private func persistElements(_ newElements: [PageElement]) {
        guard let page = currentPage else { return }
        try? store.setElements(newElements, pageID: page.id)
        if pages.indices.contains(currentIndex) {
            pages[currentIndex].elements = newElements.isEmpty ? nil : newElements
        }
    }

    /// Insere uma imagem escolhida da galeria: salva o asset, cria um elemento centralizado
    /// (~40% da largura da página, proporção da foto) e entra no modo de edição de imagem.
    private func insertImage(data: Data, ext: String) {
        guard currentPage != nil else { return }
        do {
            let assetID = try store.saveAsset(data, preferredExtension: ext)

            let size = effectiveSize
            let width = Double(size.width) * 0.4
            var height = width
            if let img = UIImage(data: data), img.size.width > 0 {
                height = width * Double(img.size.height / img.size.width)
            }
            let x = Double(size.width) / 2 - width / 2
            let y = Double(size.height) / 2 - height / 2

            let element = PageElement(assetID: assetID, x: x, y: y, width: width, height: height)
            var newElements = elements
            newElements.append(element)
            elements = newElements
            persistElements(newElements)

            selectedElementID = element.id
            imageEditMode = true
        } catch {
            errorMessage = "Não foi possível inserir a imagem: \(error.localizedDescription)"
        }
    }

    /// Importa um PDF: salva o arquivo no caderno e cria UMA página por página do PDF, cada
    /// uma com aquela página como fundo (pronta para anotar por cima). Navega para a 1ª nova.
    private func importPDF(data: Data) {
        do {
            let assetID = try store.saveAsset(data, preferredExtension: "pdf")
            let count = PDFRasterizer.pageCount(fileURL: store.assetFileURL(id: assetID))
            guard count > 0 else {
                errorMessage = "Não consegui ler páginas nesse PDF."
                return
            }
            var firstNewID: String?
            for i in 0..<count {
                let bg = PageBackground(kind: .pdf, assetID: assetID, pdfPageIndex: i)
                let page = try store.addPage(template: currentTemplate.rawValue, background: bg)
                if firstNewID == nil { firstNewID = page.id }
            }
            goToNewPage(firstNewID)
        } catch {
            errorMessage = "Não foi possível importar o PDF: \(error.localizedDescription)"
        }
    }

    /// Recebe as imagens digitalizadas (uma por página escaneada), salva cada uma e cria uma
    /// página com a imagem como fundo. Navega para a 1ª nova.
    private func scanDocuments(_ datas: [Data]) {
        guard !datas.isEmpty else { return }
        do {
            var firstNewID: String?
            for data in datas {
                let assetID = try store.saveAsset(data, preferredExtension: "jpg")
                let bg = PageBackground(kind: .image, assetID: assetID)
                let page = try store.addPage(template: currentTemplate.rawValue, background: bg)
                if firstNewID == nil { firstNewID = page.id }
            }
            goToNewPage(firstNewID)
        } catch {
            errorMessage = "Não foi possível salvar o documento: \(error.localizedDescription)"
        }
    }

    /// Recarrega e navega para a página recém-criada de `id` (se achar).
    private func goToNewPage(_ id: String?) {
        reload()
        if let id = id, let idx = pages.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            syncTemplate()
            loadElements()
        }
    }

    /// Gera o PDF do caderno e abre a folha de compartilhamento.
    private func exportPDF() {
        do {
            shareItem = ShareItem(url: try PDFExporter.makePDF(store: store))
        } catch {
            errorMessage = "Não foi possível gerar o PDF: \(error.localizedDescription)"
        }
    }

    /// Exporta a página atual como imagem (PNG) e abre a folha de compartilhamento.
    private func exportPageImage() {
        guard let page = currentPage else { return }
        do {
            shareItem = ShareItem(url: try PDFExporter.makePagePNG(store: store, page: page))
        } catch {
            errorMessage = "Não foi possível exportar a imagem: \(error.localizedDescription)"
        }
    }

    /// Cria uma caixa de texto no centro da página, seleciona-a e já abre o editor.
    private func insertTextBox() {
        guard currentPage != nil else { return }
        let size = effectiveSize
        let width = Double(size.width) * 0.5
        let height: Double = 60
        let element = PageElement(
            kind: .text,
            x: Double(size.width) / 2 - width / 2,
            y: Double(size.height) / 2 - height / 2,
            width: width,
            height: height,
            text: "",
            fontSize: 20,
            colorHex: "#000000"
        )
        var newElements = elements
        newElements.append(element)
        elements = newElements
        persistElements(newElements)

        selectedElementID = element.id
        imageEditMode = true
        beginEditText(element)
    }

    /// Abre o editor de texto de uma caixa de texto.
    private func beginEditText(_ element: PageElement) {
        editingTextElementID = element.id
        editingText = element.text ?? ""
        showTextEditor = true
    }

    /// Salva o texto editado na caixa correspondente e persiste.
    private func commitTextEdit() {
        defer { editingTextElementID = nil }
        guard let id = editingTextElementID,
              let idx = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[idx].text = editingText
        persistElements(elements)
    }

    /// Cola uma imagem que o usuário copiou (ex.: da web no Safari) como um objeto na página.
    private func pasteImage() {
        let pasteboard = UIPasteboard.general
        if let image = pasteboard.image, let data = image.pngData() {
            insertImage(data: data, ext: "png")
        } else {
            errorMessage = "Não encontrei imagem copiada. Copie uma imagem (ex.: no Safari, segure a imagem → Copiar) e tente de novo."
        }
    }
}

/// Embrulho Identifiable para a URL do PDF, usado em `.sheet(item:)`. Evitamos conformar
/// `URL` a `Identifiable` diretamente (gera aviso e pode conflitar com o sistema no futuro).
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
