import SwiftUI
import UIKit
import CadernoCore

/// Tela inicial do app: a biblioteca de cadernos, agora com PASTAS.
///
/// Mostra as pastas e os cadernos do diretório atual. Tocar numa pasta entra nela; um botão
/// "voltar" sobe um nível. Dá para criar pasta, criar caderno, renomear/apagar caderno,
/// mover caderno para uma pasta, e apagar pasta (vai para a lixeira).
///
/// Ao tocar num caderno, abre o `NotebookStore` e navega (via NavigationStack) para a
/// `NotebookView`. A navegação ENTRE PASTAS é feita por estado (`currentDir`), separada da
/// navegação que abre cadernos — assim uma não atrapalha a outra.
struct LibraryView: View {

    @EnvironmentObject private var backup: BackupManager

    @State private var notebooks: [NotebookRef] = []
    @State private var folders: [FolderRef] = []

    /// Caminho de navegação para ABRIR cadernos (por URL do pacote).
    @State private var path: [URL] = []

    /// Raiz da biblioteca (Documents) e pasta atualmente aberta.
    @State private var rootDir: URL?
    @State private var currentDir: URL?

    // Estados de diálogos.
    @State private var pendingDelete: NotebookRef?
    @State private var pendingRename: NotebookRef?
    @State private var renameText: String = ""
    @State private var pendingFolderDelete: FolderRef?
    @State private var pendingMove: NotebookRef?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showDiagnostics = false
    @State private var showBackupOptions = false
    @State private var showRestore = false
    @State private var infoMessage: String?
    @State private var errorMessage: String?

    // Senha (PIN) de caderno.
    @State private var pinPurpose: PINPurpose?
    @State private var pinTargetURL: URL?
    @State private var pinEntry = ""
    @State private var pinConfirm = ""
    /// Cadernos já desbloqueados nesta sessão (não pede senha de novo até fechar o app).
    @State private var unlockedURLs: Set<URL> = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20)]

    /// Estamos na raiz? (compara caminhos padronizados para evitar diferença de "/" final).
    private var isAtRoot: Bool {
        guard let current = currentDir, let root = rootDir else { return true }
        return current.standardizedFileURL.path == root.standardizedFileURL.path
    }

    private var screenTitle: String {
        isAtRoot ? "BonfimBook" : (currentDir?.lastPathComponent ?? "Pasta")
    }

    var body: some View {
        NavigationStack(path: $path) {
            base
        }
    }

    // MARK: - Corpo quebrado em pedaços (evita "expressão complexa demais" no iPad)

    /// Conteúdo + navegação + diálogos, montados em camadas pequenas para o compilador do
    /// Swift Playgrounds não estourar o tempo de checagem de tipos.
    private var base: some View {
        withAlerts(withDialogs(withSheets(navigatedContent)))
    }

    private var navigatedContent: some View {
        content
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .navigationDestination(for: URL.self) { url in
                notebookDestination(for: url)
            }
            .onAppear(perform: reload)
    }

    private func withSheets<V: View>(_ v: V) -> some View {
        v
            .sheet(isPresented: $showDiagnostics) {
                PenDiagnosticView()
            }
            .sheet(isPresented: boolBinding($pinPurpose)) {
                pinSheet
            }
            .sheet(isPresented: $showRestore) {
                RestoreView(
                    backup: backup,
                    libraryRoot: rootDir ?? ((try? NotebookLibrary.defaultDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory())),
                    onFinished: { reload() }
                )
            }
    }

    private func withDialogs<V: View>(_ v: V) -> some View {
        v
            .confirmationDialog(
                "Apagar este caderno?",
                isPresented: boolBinding($pendingDelete),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { ref in
                Button("Apagar \u{201C}\(ref.title)\u{201D}", role: .destructive) { delete(ref) }
                Button("Cancelar", role: .cancel) { pendingDelete = nil }
            } message: { ref in
                Text("O caderno \u{201C}\(ref.title)\u{201D} vai para a lixeira. Você poderá recuperá-lo depois.")
            }
            .confirmationDialog(
                "Apagar esta pasta?",
                isPresented: boolBinding($pendingFolderDelete),
                titleVisibility: .visible,
                presenting: pendingFolderDelete
            ) { folder in
                Button("Apagar \u{201C}\(folder.name)\u{201D}", role: .destructive) { deleteFolder(folder) }
                Button("Cancelar", role: .cancel) { pendingFolderDelete = nil }
            } message: { folder in
                Text("A pasta \u{201C}\(folder.name)\u{201D} e tudo dentro dela vai para a lixeira.")
            }
            .confirmationDialog(
                "Mover para qual pasta?",
                isPresented: boolBinding($pendingMove),
                titleVisibility: .visible,
                presenting: pendingMove
            ) { ref in
                moveTargets(for: ref)
                Button("Cancelar", role: .cancel) { pendingMove = nil }
            }
            .confirmationDialog(
                "Backup dos seus cadernos",
                isPresented: $showBackupOptions,
                titleVisibility: .visible
            ) {
                Button("Escolher pasta de backup (iCloud)") { chooseBackupFolder() }
                Button("Fazer backup agora") { backupNow() }
                Button("Restaurar do backup") { showRestore = true }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Guarde uma cópia de TODOS os cadernos numa pasta do iCloud Drive, fora do app. Assim, mesmo que o app seja apagado ou reinstalado, suas anotações continuam salvas.")
            }
    }

    private func withAlerts<V: View>(_ v: V) -> some View {
        v
            .alert("Renomear caderno", isPresented: boolBinding($pendingRename)) {
                TextField("Nome do caderno", text: $renameText)
                Button("Cancelar", role: .cancel) { pendingRename = nil }
                Button("Salvar") { renameConfirmed() }
            } message: {
                Text("Escolha um novo nome para este caderno.")
            }
            .alert("Nova pasta", isPresented: $showNewFolder) {
                TextField("Nome da pasta", text: $newFolderName)
                Button("Cancelar", role: .cancel) {}
                Button("Criar") { createFolder() }
            } message: {
                Text("Dê um nome para a nova pasta.")
            }
            .alert(
                "Algo deu errado",
                isPresented: boolBinding($errorMessage),
                presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { msg in
                Text(msg)
            }
            .alert(
                "Backup",
                isPresented: boolBinding($infoMessage),
                presenting: infoMessage
            ) { _ in
                Button("OK", role: .cancel) { infoMessage = nil }
            } message: { msg in
                Text(msg)
            }
    }

    // MARK: - Conteúdo

    @ViewBuilder
    private var content: some View {
        if folders.isEmpty && notebooks.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !folders.isEmpty {
                        sectionHeader("Pastas")
                        foldersGrid
                    }
                    if !notebooks.isEmpty {
                        sectionHeader("Cadernos")
                        notebooksGrid
                    }
                }
                .padding(20)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private var foldersGrid: some View {
        LazyVGrid(columns: columns, spacing: 24) {
            ForEach(folders, id: \.url) { folder in
                Button {
                    enterFolder(folder.url)
                } label: {
                    FolderCell(name: folder.name)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        pendingFolderDelete = folder
                    } label: {
                        Label("Apagar pasta", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var notebooksGrid: some View {
        LazyVGrid(columns: columns, spacing: 24) {
            ForEach(notebooks, id: \.url) { ref in
                Button {
                    openOrGate(ref)
                } label: {
                    NotebookCoverCell(ref: ref)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        renameText = ref.title
                        pendingRename = ref
                    } label: {
                        Label("Renomear", systemImage: "pencil")
                    }
                    if !folders.isEmpty || !isAtRoot {
                        Button {
                            pendingMove = ref
                        } label: {
                            Label("Mover para pasta", systemImage: "folder")
                        }
                    }
                    if ref.isLocked {
                        Button {
                            startPIN(.remove, for: ref.url)
                        } label: {
                            Label("Remover senha", systemImage: "lock.open")
                        }
                    } else {
                        Button {
                            startPIN(.setNew, for: ref.url)
                        } label: {
                            Label("Proteger com senha", systemImage: "lock")
                        }
                    }
                    Button(role: .destructive) {
                        pendingDelete = ref
                    } label: {
                        Label("Apagar", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// Botões de destino do "Mover para pasta": cada subpasta da pasta atual, e — se não
    /// estivermos na raiz — a opção de subir um nível.
    @ViewBuilder
    private func moveTargets(for ref: NotebookRef) -> some View {
        ForEach(folders, id: \.url) { folder in
            Button(folder.name) { moveNotebook(ref, to: folder.url) }
        }
        if !isAtRoot, let parent = currentDir?.deletingLastPathComponent() {
            Button("⬆︎ Nível acima") { moveNotebook(ref, to: parent) }
        }
    }

    // MARK: - Estado vazio

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: isAtRoot ? "book.closed" : "folder")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(isAtRoot ? "Crie seu primeiro caderno" : "Pasta vazia")
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

    // MARK: - Barra superior

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            if !isAtRoot {
                Button(action: goUp) {
                    Label("Voltar", systemImage: "chevron.left")
                }
                .accessibilityLabel("Voltar para a pasta anterior")
            }
            Button {
                showBackupOptions = true
            } label: {
                BackupStatusView()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Opções de backup")
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                newFolderName = ""
                showNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel("Nova pasta")

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

    // MARK: - Destino de navegação (abrir caderno)

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

    /// Resolve raiz/pasta atual e recarrega pastas + cadernos do diretório atual.
    private func reload() {
        if rootDir == nil { rootDir = try? NotebookLibrary.defaultDirectory() }
        if currentDir == nil { currentDir = rootDir }
        guard let dir = currentDir else {
            folders = []; notebooks = []
            return
        }
        folders = (try? NotebookLibrary.listFolders(in: dir)) ?? []
        notebooks = (try? NotebookLibrary.list(in: dir)) ?? []
    }

    private func enterFolder(_ url: URL) {
        currentDir = url
        reload()
    }

    private func goUp() {
        guard !isAtRoot else { return }
        currentDir = currentDir?.deletingLastPathComponent()
        reload()
    }

    /// Cria um caderno na pasta ATUAL, com título "Caderno N" e cor sorteada, e o abre.
    private func createNotebook() {
        guard let dir = currentDir ?? (try? NotebookLibrary.defaultDirectory()) else {
            errorMessage = "Não foi possível localizar a pasta de cadernos."
            return
        }
        let title = nextTitle()
        let hex = Self.coverPalette.randomElement() ?? Self.defaultCoverHex
        do {
            let store = try NotebookLibrary.create(in: dir, title: title, coverColorHex: hex)
            reload()
            open(store.packageURL)
        } catch {
            errorMessage = "Não foi possível criar o caderno: \(error.localizedDescription)"
        }
    }

    private func createFolder() {
        guard let dir = currentDir else { return }
        do {
            _ = try NotebookLibrary.createFolder(in: dir, name: newFolderName)
            reload()
        } catch {
            errorMessage = "Não foi possível criar a pasta: \(error.localizedDescription)"
        }
    }

    private func open(_ url: URL) {
        path.append(url)
    }

    /// Abre o caderno; se tiver senha e ainda não foi desbloqueado nesta sessão, pede o PIN.
    private func openOrGate(_ ref: NotebookRef) {
        if ref.isLocked && !unlockedURLs.contains(ref.url) {
            startPIN(.unlock, for: ref.url)
        } else {
            open(ref.url)
        }
    }

    private func startPIN(_ purpose: PINPurpose, for url: URL) {
        pinTargetURL = url
        pinEntry = ""
        pinConfirm = ""
        pinPurpose = purpose
    }

    /// Trata o "OK" da telinha de senha conforme o propósito (definir/desbloquear/remover).
    private func submitPIN() {
        guard let purpose = pinPurpose, let url = pinTargetURL else { return }
        switch purpose {
        case .setNew:
            let pin = pinEntry.trimmingCharacters(in: .whitespaces)
            guard pin.count >= 4 else {
                errorMessage = "A senha precisa de ao menos 4 dígitos."
                return
            }
            guard pin == pinConfirm.trimmingCharacters(in: .whitespaces) else {
                errorMessage = "As senhas não conferem."
                return
            }
            do {
                let store = try NotebookStore.open(packageURL: url)
                try store.setLockHash(PINHasher.hash(pin))
                pinPurpose = nil
                reload()
            } catch {
                errorMessage = "Não foi possível proteger o caderno: \(error.localizedDescription)"
            }

        case .unlock:
            do {
                let hash = try NotebookStore.open(packageURL: url).loadManifest().lockPINHash
                if PINHasher.matches(pinEntry, hash: hash) {
                    unlockedURLs.insert(url)
                    pinPurpose = nil
                    open(url)
                } else {
                    errorMessage = "Senha incorreta."
                }
            } catch {
                errorMessage = "Não foi possível abrir o caderno: \(error.localizedDescription)"
            }

        case .remove:
            do {
                let store = try NotebookStore.open(packageURL: url)
                let hash = try store.loadManifest().lockPINHash
                if PINHasher.matches(pinEntry, hash: hash) {
                    try store.setLockHash(nil)
                    pinPurpose = nil
                    reload()
                } else {
                    errorMessage = "Senha incorreta."
                }
            } catch {
                errorMessage = "Não foi possível remover a senha: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Telinha de senha (PIN)

    private var pinTitle: String {
        switch pinPurpose {
        case .setNew: return "Proteger com senha"
        case .unlock: return "Digite a senha"
        case .remove: return "Remover senha"
        case .none: return ""
        }
    }

    private var pinSheet: some View {
        NavigationStack {
            Form {
                SecureField("Senha (mín. 4 dígitos)", text: $pinEntry)
                    .keyboardType(.numberPad)
                if pinPurpose == .setNew {
                    SecureField("Confirmar senha", text: $pinConfirm)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle(pinTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { pinPurpose = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { submitPIN() }
                }
            }
        }
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

    private func deleteFolder(_ folder: FolderRef) {
        pendingFolderDelete = nil
        do {
            try NotebookLibrary.moveToTrash(folder.url)
            reload()
        } catch {
            errorMessage = "Não foi possível apagar a pasta: \(error.localizedDescription)"
        }
    }

    private func moveNotebook(_ ref: NotebookRef, to directory: URL) {
        pendingMove = nil
        do {
            _ = try NotebookLibrary.move(ref.url, to: directory)
            reload()
        } catch {
            errorMessage = "Não foi possível mover o caderno: \(error.localizedDescription)"
        }
    }

    private func renameConfirmed() {
        guard let ref = pendingRename else { return }
        pendingRename = nil
        do {
            let store = try NotebookStore.open(packageURL: ref.url)
            try store.setTitle(renameText)
            reload()
        } catch {
            errorMessage = "Não foi possível renomear o caderno: \(error.localizedDescription)"
        }
    }

    private func nextTitle() -> String {
        let existing = Set(notebooks.map { $0.title })
        var n = notebooks.count + 1
        while existing.contains("Caderno \(n)") { n += 1 }
        return "Caderno \(n)"
    }

    // MARK: - Backup

    /// Abre o seletor de pasta do sistema para o usuário escolher onde guardar a cópia
    /// (idealmente uma pasta no iCloud Drive).
    private func chooseBackupFolder() {
        guard let vc = Self.topViewController() else {
            errorMessage = "Não consegui abrir o seletor de pasta agora. Tente de novo."
            return
        }
        backup.chooseFolder(presenting: vc)
    }

    /// Copia todos os cadernos para a pasta escolhida (e uma cópia local de segurança).
    private func backupNow() {
        let root = rootDir ?? (try? NotebookLibrary.defaultDirectory())
        guard let root = root else {
            errorMessage = "Não foi possível localizar a pasta de cadernos."
            return
        }
        backup.backupEverything(libraryRoot: root)
        if backup.hasFolder() {
            infoMessage = "Backup em andamento. Quando a bolinha ficar verde, está tudo salvo na sua pasta."
        } else {
            infoMessage = "Fiz uma cópia local de segurança. Para proteger contra apagar o app, toque em \u{201C}Escolher pasta de backup (iCloud)\u{201D}."
        }
    }

    /// Acha a tela (UIViewController) ativa para apresentar o seletor de pasta.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// Helper: transforma um `@State` opcional num `Binding<Bool>` para diálogos/alertas.
    private func boolBinding<T>(_ source: Binding<T?>) -> Binding<Bool> {
        Binding(get: { source.wrappedValue != nil },
                set: { if !$0 { source.wrappedValue = nil } })
    }

    // MARK: - Paleta de capas (hex fixos)

    static let defaultCoverHex = "#4E86C7"
    static let coverPalette: [String] = [
        "#E8705A", "#F2B134", "#5AAE7A", "#4E86C7", "#8E6FC0", "#D96FA0"
    ]
}

/// Propósito da telinha de senha: criar, desbloquear para abrir, ou remover.
private enum PINPurpose: Equatable {
    case setNew
    case unlock
    case remove
}

// MARK: - Célula de PASTA

private struct FolderCell: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Célula de capa

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
            .overlay(alignment: .topTrailing) {
                if ref.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(8)
                }
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

private enum LibraryColor {
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
