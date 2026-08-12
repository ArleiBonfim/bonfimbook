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
    // Modo estudo: anteparos ficam tocáveis (revelar/esconder); não dá pra escrever.
    @State private var studyMode = false
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
    // Backup / restauração (também acessível aqui dentro, não só na tela inicial).
    @State private var showBackupOptions = false
    @State private var showRestore = false
    @State private var backupInfo: String?
    // Edição de caixa de texto.
    @State private var editingTextElementID: String?
    @State private var editingText = ""
    @State private var showTextEditor = false
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?
    // Geração de imagem por IA.
    @State private var showAIPrompt = false
    @State private var aiPrompt = ""
    @State private var isGenerating = false
    @State private var showAppleGen = false
    @State private var showGenerateChoice = false
    // Organizar anotação (IA de texto).
    @State private var showOrganizeChoice = false
    @State private var isOrganizing = false
    @State private var organizeText = ""
    @State private var showOrganizeResult = false
    @State private var isRemovingBG = false

    // Dimensões lógicas de referência quando ainda não sabemos o tamanho real da tela.
    private static let fallbackSize = CGSize(width: 768, height: 1024)

    var body: some View {
        withNotebookAlerts(withNotebookSheets(chrome))
    }

    // MARK: - Corpo quebrado em pedaços (evita "expressão complexa demais" no iPad)

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            // Barra fina de canetas (nossa, discreta). Some no modo imagem/estudo e quando
            // o usuário prefere a paleta flutuante completa da Apple.
            if showPenBar {
                PenToolbarView(
                    controller: canvasController,
                    onInsertText: { insertTextBox() },
                    onInsertImage: { showPhotoPicker = true },
                    onPasteImage: { pasteImage() },
                    onAddCover: { insertCover() },
                    onSmooth: { canvasController.smoothStrokes() },
                    onGenerateImage: { startGenerateImage() }
                )
                Divider()
            }
            if imageEditMode || studyMode {
                modeBanner
                Divider()
            }
            if canvasController.selectionActive {
                selectBanner
                Divider()
            }
            pageArea
            Divider()
            bottomBar
        }
        .navigationBarHidden(true)
        .overlay { if let msg = busyMessage { busyOverlay(msg) } }
        .appleImagePlaygroundSheet(isPresented: $showAppleGen, seed: "") { data in
            insertImage(data: data, ext: "png")
        }
        .onAppear(perform: reload)
    }

    private func withNotebookSheets<V: View>(_ v: V) -> some View {
        v
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
            .sheet(isPresented: $showOrganizeResult) {
                OrganizeResultView(text: organizeText) { text in
                    createPageWithText(text)
                }
            }
            .sheet(isPresented: $showAIPrompt) {
                AIPromptSheet(text: $aiPrompt) { generateOnlineImage() }
            }
            .sheet(isPresented: $showRestore) {
                RestoreView(
                    backup: backup,
                    libraryRoot: (try? NotebookLibrary.defaultDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory()),
                    onFinished: {}
                )
            }
    }

    private func withNotebookAlerts<V: View>(_ v: V) -> some View {
        v
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
            .confirmationDialog("Backup dos seus cadernos", isPresented: $showBackupOptions, titleVisibility: .visible) {
                Button("Escolher pasta de backup (iCloud)") { chooseBackupFolder() }
                Button("Fazer backup agora") { backupNow() }
                Button("Restaurar do backup") { showRestore = true }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Guarde uma cópia de TODOS os cadernos numa pasta do iCloud Drive, fora do app. Assim, mesmo que o app seja apagado, suas anotações continuam salvas.")
            }
            .alert("Backup", isPresented: Binding(get: { backupInfo != nil }, set: { if !$0 { backupInfo = nil } }), presenting: backupInfo) { _ in
                Button("OK", role: .cancel) { backupInfo = nil }
            } message: { msg in
                Text(msg)
            }
            .confirmationDialog("Gerar imagem", isPresented: $showGenerateChoice, titleVisibility: .visible) {
                if appleImageGenAvailable {
                    Button("No iPad (Apple) — melhor qualidade") { showAppleGen = true }
                }
                Button("Online (grátis)") { aiPrompt = ""; showAIPrompt = true }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("O gerador da Apple roda no seu iPad, entende melhor e é privado. O online é grátis, mas mais simples.")
            }
            .confirmationDialog("Organizar anotação", isPresented: $showOrganizeChoice, titleVisibility: .visible) {
                if AppleTextAI.available {
                    Button("No iPad (privado)") { organizeNotes(useApple: true) }
                }
                Button("Online (grátis)") { organizeNotes(useApple: false) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Vou ler sua letra e o texto digitado e arrumar. \u{201C}Online\u{201D} envia o texto a um serviço externo grátis.")
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

    /// A barra fina de canetas aparece quando estamos escrevendo (não no modo imagem/estudo)
    /// e o usuário não pediu a paleta completa da Apple.
    private var showPenBar: Bool {
        !canvasController.useSystemPicker && !imageEditMode && !studyMode
            && !canvasController.selectionActive
    }

    // MARK: - Área central (papel + imagens + canvas)

    private var pageArea: some View {
        GeometryReader { geo in
            ZStack {
                // CAMADAS DE TRÁS (papel + imagens): acompanham o zoom/rolagem do canvas via
                // o MESMO scaleEffect/offset, para a PÁGINA INTEIRA ampliar junto (não só o
                // traço). O `anchor: .topLeading` casa com a origem do conteúdo do canvas.
                backLayers(size: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(canvasController.zoomScale, anchor: .topLeading)
                    .offset(x: -canvasController.contentOffset.x,
                            y: -canvasController.contentOffset.y)
                    .allowsHitTesting(imageEditMode || studyMode)

                // Traço à mão: por cima, é ele quem DIRIGE o zoom (fica nítido ao ampliar).
                if let page = currentPage {
                    PKCanvasRepresentable(
                        store: store,
                        backup: backup,
                        pageID: page.id,
                        drawingPolicy: $drawingPolicy,
                        controller: canvasController
                    )
                    .allowsHitTesting(!imageEditMode && !studyMode && !canvasController.selectionActive)
                    // Recria o canvas ao trocar de página: garante a carga inicial correta
                    // e descarta qualquer debounce pendente da página anterior.
                    .id(page.id)
                } else {
                    Text("Caderno vazio")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // ANTEPAROS por cima da tinta (para tampar de verdade). Mesmo zoom das demais
                // camadas; recebe toque no modo imagem/estudo (mover ou revelar).
                coverLayer(size: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(canvasController.zoomScale, anchor: .topLeading)
                    .offset(x: -canvasController.contentOffset.x,
                            y: -canvasController.contentOffset.y)
                    .allowsHitTesting(imageEditMode || studyMode)

                // NOSSO laço: por cima de tudo quando o modo laço está ligado (zoom fica em 1,
                // então as coordenadas batem 1:1 com a escrita).
                if canvasController.selectionActive {
                    LassoSelectionView(controller: canvasController)
                }
            }
            .clipped()
            .onAppear { pageSize = geo.size }
            .onChange(of: geo.size) { pageSize = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Papel (ou documento importado) + imagens/texto/anteparos. Fica atrás do canvas e é
    /// o bloco que recebe o zoom da página. Separado num sub-view para não estourar o
    /// verificador de tipos do iPad.
    @ViewBuilder
    private func backLayers(size: CGSize) -> some View {
        ZStack {
            if let page = currentPage, let bg = page.background {
                PageBackgroundContentView(store: store, background: bg)
            } else {
                PaperBackgroundView(template: currentTemplate)
            }

            if currentPage != nil {
                // Toque em espaço vazio desseleciona (só no modo de edição de imagem).
                if imageEditMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedElementID = nil }
                }

                // Imagens e caixas de texto (abaixo da tinta). Os ANTEPAROS saem daqui —
                // vão para a camada de cima (`coverLayer`) para conseguirem tampar a escrita.
                PageImageLayerView(
                    store: store,
                    elements: $elements,
                    selectedElementID: $selectedElementID,
                    studyMode: studyMode,
                    onCommit: { newElements in persistElements(newElements) },
                    onEditText: { element in beginEditText(element) },
                    onRemoveBackground: { element in removeBackground(for: element) },
                    onDuplicate: { element in duplicateElement(element) },
                    onRotate: { element in rotateElement(element) },
                    onBringFront: { element in bringElementToFront(element) },
                    onSendBack: { element in sendElementToBack(element) },
                    onSetColor: { element, hex in setElementColor(element, hex) },
                    filter: { $0.kind != .cover }
                )
            }
        }
    }

    /// Camada dos ANTEPAROS de estudo — desenhada ACIMA da tinta para realmente TAMPAR a
    /// escrita (antes ficava atrás e a escrita aparecia por cima). Acompanha o mesmo zoom.
    @ViewBuilder
    private func coverLayer(size: CGSize) -> some View {
        if currentPage != nil {
            PageImageLayerView(
                store: store,
                elements: $elements,
                selectedElementID: $selectedElementID,
                studyMode: studyMode,
                onCommit: { newElements in persistElements(newElements) },
                onEditText: { element in beginEditText(element) },
                onRemoveBackground: { element in removeBackground(for: element) },
                onDuplicate: { element in duplicateElement(element) },
                onRotate: { element in rotateElement(element) },
                onBringFront: { element in bringElementToFront(element) },
                onSendBack: { element in sendElementToBack(element) },
                onSetColor: { element, hex in setElementColor(element, hex) },
                filter: { $0.kind == .cover }
            )
        }
    }

    /// Faixa que avisa qual modo especial está ligado (imagem/estudo), onde a caneta NÃO
    /// escreve — assim ninguém fica preso sem entender por que não consegue riscar.
    private var modeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: imageEditMode ? "hand.point.up.left.fill" : "eye.fill")
            Text(imageEditMode
                 ? "Modo mover imagens — a caneta não escreve aqui."
                 : "Modo estudo — a caneta não escreve aqui.")
                .font(.caption.weight(.medium))
            Spacer()
            Button("Voltar a escrever") {
                imageEditMode = false
                studyMode = false
                selectedElementID = nil
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12))
    }

    /// Faixa de ações do NOSSO laço: aumentar/diminuir, cor, duplicar, apagar (quando há
    /// escrita selecionada) e sair. A instrução aparece enquanto nada está selecionado.
    private var selectBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "lasso")
            if canvasController.selectionBounds != nil {
                Button { canvasController.scaleSelection(1.2) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .accessibilityLabel("Aumentar")
                Button { canvasController.scaleSelection(0.8) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .accessibilityLabel("Diminuir")
                selectColorMenu
                Button { canvasController.duplicateSelection() } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .accessibilityLabel("Duplicar")
                Button(role: .destructive) { canvasController.deleteSelection() } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Apagar")
                Text("arraste dentro da caixa para mover")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Cerque a escrita com o laço para selecionar.")
                    .font(.caption.weight(.medium))
            }
            Spacer()
            Button("Sair") { canvasController.endSelectMode() }
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12))
    }

    /// Menu de cor para a escrita selecionada.
    private var selectColorMenu: some View {
        Menu {
            selectColorButton("Preto", "#000000")
            selectColorButton("Azul", "#1E6FE8")
            selectColorButton("Vermelho", "#E23B3B")
            selectColorButton("Verde", "#2F9E44")
            selectColorButton("Laranja", "#F08C00")
            selectColorButton("Roxo", "#7C4DD6")
        } label: {
            Image(systemName: "paintpalette")
        }
        .accessibilityLabel("Mudar cor")
    }

    private func selectColorButton(_ name: String, _ hex: String) -> some View {
        Button(name) {
            if let ui = lassoUIColor(hex) { canvasController.colorSelection(ui) }
        }
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
                if imageEditMode { studyMode = false }
                if !imageEditMode { selectedElementID = nil }
                // O zoom do canvas não fica ativo no modo imagem; zera para as camadas não
                // ficarem ampliadas e desalinhadas ao mexer nas imagens.
                canvasController.resetZoom()
            } label: {
                Image(systemName: imageEditMode ? "hand.point.up.left.fill" : "hand.point.up.left")
            }
            .tint(imageEditMode ? .accentColor : nil)
            .accessibilityLabel(imageEditMode ? "Sair do modo imagem" : "Mexer nas imagens")

            // Modo estudo (liga/desliga): tocar nos anteparos revela/esconde.
            Button {
                studyMode.toggle()
                if studyMode { imageEditMode = false; selectedElementID = nil }
                canvasController.resetZoom()
            } label: {
                Image(systemName: studyMode ? "eye.fill" : "eye.slash")
            }
            .tint(studyMode ? .accentColor : nil)
            .accessibilityLabel(studyMode ? "Sair do modo estudo" : "Modo estudo")

            // Laço (nosso): selecionar a escrita para redimensionar/mudar cor/mover.
            Button {
                if canvasController.selectionActive {
                    canvasController.endSelectMode()
                } else {
                    imageEditMode = false
                    studyMode = false
                    selectedElementID = nil
                    canvasController.resetZoom()
                    canvasController.beginSelectMode()
                }
            } label: {
                Image(systemName: canvasController.selectionActive ? "lasso.badge.sparkles" : "lasso")
            }
            .tint(canvasController.selectionActive ? .accentColor : nil)
            .accessibilityLabel("Selecionar escrita com o laço")

            // Modo formas (liga/desliga): ao levantar a caneta, o traço vira forma perfeita.
            Button {
                canvasController.shapeMode.toggle()
            } label: {
                Image(systemName: canvasController.shapeMode ? "square.on.circle.fill" : "square.on.circle")
            }
            .tint(canvasController.shapeMode ? .accentColor : nil)
            .accessibilityLabel(canvasController.shapeMode ? "Desligar modo formas" : "Modo formas")

            // Alterna entre a barra fina (discreta) e a paleta completa flutuante da Apple.
            Button {
                canvasController.useSystemPicker.toggle()
                canvasController.syncPickerVisibility()
            } label: {
                Image(systemName: canvasController.useSystemPicker ? "paintpalette.fill" : "paintpalette")
            }
            .tint(canvasController.useSystemPicker ? .accentColor : nil)
            .accessibilityLabel(canvasController.useSystemPicker ? "Usar barra fina de canetas" : "Abrir paleta completa da Apple")

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

            Button {
                insertCover()
            } label: {
                Label("Adicionar anteparo (estudo)", systemImage: "rectangle.slash")
            }

            Button {
                canvasController.smoothStrokes()
            } label: {
                Label("Melhorar traço (suavizar)", systemImage: "wand.and.stars")
            }

            Divider()

            Button {
                startGenerateImage()
            } label: {
                Label("Gerar imagem (IA)", systemImage: "sparkles")
            }

            Button {
                showOrganizeChoice = true
            } label: {
                Label("Organizar anotação (IA)", systemImage: "wand.and.stars.inverse")
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

            Button {
                showBackupOptions = true
            } label: {
                Label("Backup e restauração (iCloud)", systemImage: "externaldrive.badge.icloud")
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
        // Toda página abre no modo ESCREVER. Sem isto, o "modo imagem"/"modo estudo" (que
        // desligam a caneta) ficavam presos ao trocar de página — e a pessoa não conseguia
        // riscar (ex.: numa página de PDF recém-importada). Bug do "não deixa riscar".
        imageEditMode = false
        studyMode = false
        // O laço vale para a escrita da página atual; ao trocar de página, sai do modo laço
        // (o canvas é recriado e a seleção antiga não faz mais sentido).
        canvasController.endSelectMode()
        // Cada página começa em 100%. O canvas é recriado ao trocar de página (.id), então
        // zeramos o zoom espelhado para o papel não herdar o zoom da página anterior.
        canvasController.resetZoom()
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

    /// Duplica um elemento (imagem/texto/anteparo) deslocado um pouco e o seleciona.
    private func duplicateElement(_ element: PageElement) {
        let copy = PageElement(
            kind: element.kind, assetID: element.assetID,
            x: element.x + 24, y: element.y + 24,
            width: element.width, height: element.height,
            rotation: element.rotation, text: element.text,
            fontSize: element.fontSize, colorHex: element.colorHex
        )
        var newElements = elements
        newElements.append(copy)
        elements = newElements
        persistElements(newElements)
        selectedElementID = copy.id
    }

    /// Gira o elemento em 90°.
    private func rotateElement(_ element: PageElement) {
        guard let idx = elements.firstIndex(where: { $0.id == element.id }) else { return }
        elements[idx].rotation += .pi / 2
        persistElements(elements)
    }

    /// Move o elemento para o fim da lista (fica na FRENTE dos demais).
    private func bringElementToFront(_ element: PageElement) {
        guard let idx = elements.firstIndex(where: { $0.id == element.id }) else { return }
        let el = elements.remove(at: idx)
        elements.append(el)
        persistElements(elements)
    }

    /// Move o elemento para o começo da lista (fica ATRÁS dos demais).
    private func sendElementToBack(_ element: PageElement) {
        guard let idx = elements.firstIndex(where: { $0.id == element.id }) else { return }
        let el = elements.remove(at: idx)
        elements.insert(el, at: 0)
        persistElements(elements)
    }

    /// Troca a cor de um texto ou anteparo.
    private func setElementColor(_ element: PageElement, _ hex: String) {
        guard let idx = elements.firstIndex(where: { $0.id == element.id }) else { return }
        elements[idx].colorHex = hex
        persistElements(elements)
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

    /// Cria um anteparo de estudo (retângulo opaco) no centro e entra no modo de mexer para
    /// posicionar. Depois, no "modo estudo", tocar nele revela/esconde o que está por baixo.
    private func insertCover() {
        guard currentPage != nil else { return }
        let size = effectiveSize
        let width = Double(size.width) * 0.6
        let height: Double = 70
        let element = PageElement(
            kind: .cover,
            x: Double(size.width) / 2 - width / 2,
            y: Double(size.height) / 2 - height / 2,
            width: width,
            height: height,
            colorHex: "#B8BEC6"
        )
        var newElements = elements
        newElements.append(element)
        elements = newElements
        persistElements(newElements)

        selectedElementID = element.id
        studyMode = false
        imageEditMode = true
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

    /// Abre o seletor de pasta do sistema para escolher onde guardar o backup (iCloud Drive).
    private func chooseBackupFolder() {
        guard let vc = Self.topViewController() else {
            errorMessage = "Não consegui abrir o seletor de pasta agora. Tente de novo."
            return
        }
        backup.chooseFolder(presenting: vc)
    }

    /// Copia todos os cadernos para a pasta escolhida (e uma cópia local de segurança).
    private func backupNow() {
        let root = (try? NotebookLibrary.defaultDirectory()) ?? store.packageURL.deletingLastPathComponent()
        backup.backupEverything(libraryRoot: root)
        backupInfo = backup.hasFolder()
            ? "Backup em andamento. Quando a bolinha ficar verde, está tudo salvo na sua pasta."
            : "Fiz uma cópia local de segurança. Para proteger contra apagar o app, toque em \u{201C}Escolher pasta de backup (iCloud)\u{201D}."
    }

    /// Acha a tela ativa para apresentar o seletor de pasta.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// Começa a gerar imagem: se o iPad tem o gerador da Apple (melhor), pergunta qual usar;
    /// senão vai direto pro online grátis.
    private func startGenerateImage() {
        if appleImageGenAvailable {
            showGenerateChoice = true
        } else {
            aiPrompt = ""
            showAIPrompt = true
        }
    }

    /// Gera uma imagem pelo serviço grátis online e a insere na página (em segundo plano,
    /// mostrando um aviso enquanto gera).
    private func generateOnlineImage() {
        let prompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isGenerating = true
        Task {
            do {
                let data = try await AIImageService.generate(prompt: prompt)
                await MainActor.run {
                    isGenerating = false
                    insertImage(data: data, ext: "jpg")
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    errorMessage = "Não consegui gerar a imagem: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Mensagem do aviso "ocupado" (nil = nada em andamento).
    private var busyMessage: String? {
        if isGenerating { return "Gerando imagem…" }
        if isOrganizing { return "Organizando…" }
        if isRemovingBG { return "Removendo fundo…" }
        return nil
    }

    /// Cobertura translúcida com um aviso enquanto a IA trabalha (imagem ou organização).
    private func busyOverlay(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(text)
                    .font(.subheadline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Organizar anotação (IA de texto)

    /// Junta o texto (digitado + reconhecido da letra) e organiza com IA (Apple ou online).
    private func organizeNotes(useApple: Bool) {
        let snapshot = pages
        isOrganizing = true
        Task {
            let gathered = await Self.gatherText(from: snapshot, store: store)
            let trimmed = gathered.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await MainActor.run {
                    isOrganizing = false
                    errorMessage = "Não encontrei texto pra organizar nesta anotação. Escreva/digite algo primeiro."
                }
                return
            }
            do {
                let result = useApple ? try await AppleTextAI.organize(trimmed)
                                      : try await AITextService.organize(trimmed)
                await MainActor.run {
                    isOrganizing = false
                    organizeText = result
                    showOrganizeResult = true
                }
            } catch {
                await MainActor.run {
                    isOrganizing = false
                    errorMessage = "Não consegui organizar: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Percorre todas as páginas: pega o texto digitado (caixas de texto) e reconhece a letra
    /// (OCR) de cada traço. Roda fora da main thread (é pesado).
    private static func gatherText(from pages: [PageMeta], store: NotebookStore) async -> String {
        var parts: [String] = []
        for page in pages {
            if let elements = page.elements {
                for element in elements where element.kind == .text {
                    if let t = element.text, !t.isEmpty { parts.append(t) }
                }
            }
            if let data = try? store.readDrawing(pageID: page.id),
               let drawing = try? PKDrawing(data: data) {
                let bounds = drawing.bounds
                if bounds.width > 0, bounds.height > 0 {
                    let image = drawing.image(from: bounds, scale: 2)
                    let ocr = OCRService.recognizeText(in: image)
                    if !ocr.isEmpty { parts.append(ocr) }
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Remove o fundo da imagem selecionada (no próprio iPad) e troca o asset pela versão
    /// com fundo transparente. Roda fora da main thread (é pesado).
    private func removeBackground(for element: PageElement) {
        guard element.kind == .image else { return }
        guard #available(iOS 17.0, *) else {
            errorMessage = "Remover fundo precisa de iPadOS 17 ou mais novo."
            return
        }
        let assetURL = store.assetFileURL(id: element.assetID)
        let elementID = element.id
        isRemovingBG = true
        Task {
            let png: Data? = await Task.detached(priority: .userInitiated) {
                guard let img = UIImage(contentsOfFile: assetURL.path) else { return nil }
                if #available(iOS 17.0, *) {
                    return BackgroundRemover.removeBackground(from: img)?.pngData()
                }
                return nil
            }.value

            await MainActor.run {
                isRemovingBG = false
                guard let png = png else {
                    errorMessage = "Não consegui separar o objeto do fundo nesta imagem."
                    return
                }
                do {
                    let newAsset = try store.saveAsset(png, preferredExtension: "png")
                    if let idx = elements.firstIndex(where: { $0.id == elementID }) {
                        elements[idx].assetID = newAsset
                        persistElements(elements)
                    }
                } catch {
                    errorMessage = "Não consegui salvar a imagem sem fundo: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Cria uma página nova com o texto organizado dentro de uma caixa de texto.
    private func createPageWithText(_ text: String) {
        guard let page = try? store.addPage(template: currentTemplate.rawValue) else { return }
        let size = effectiveSize
        let element = PageElement(
            kind: .text,
            x: 40,
            y: 40,
            width: Double(size.width) - 80,
            height: Double(size.height) - 80,
            text: text,
            fontSize: 18,
            colorHex: "#000000"
        )
        try? store.setElements([element], pageID: page.id)
        goToNewPage(page.id)
    }
}

/// Embrulho Identifiable para a URL do PDF, usado em `.sheet(item:)`. Evitamos conformar
/// `URL` a `Identifiable` diretamente (gera aviso e pode conflitar com o sistema no futuro).
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Converte "#RRGGBB" em `UIColor` (para recolorir a escrita selecionada pelo laço).
fileprivate func lassoUIColor(_ hex: String) -> UIColor? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
    let r = CGFloat((value >> 16) & 0xFF) / 255
    let g = CGFloat((value >> 8) & 0xFF) / 255
    let b = CGFloat(value & 0xFF) / 255
    return UIColor(red: r, green: g, blue: b, alpha: 1)
}
