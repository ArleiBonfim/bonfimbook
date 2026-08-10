# CONTRATO — Caderno, Fase 0

Este arquivo é a fonte da verdade para todos os agentes. Implemente EXATAMENTE as
assinaturas públicas e a estrutura de pastas abaixo. Se achar que algo está errado,
adicione um comentário `// NOTA:` no código, mas mantenha a assinatura como está — a
integração depende disso. Você NÃO consegue compilar (dev em Windows, sem Mac). Não rode
`swift build`/`swift test`/`xcodebuild`. Apenas escreva Swift idiomático e cuidadoso.

Swift 5.9. Alvo iPadOS. Zero dependências de terceiros.

## Arquitetura em 2 camadas (decisão fechada)

```
Caderno/                                  ← raiz do repo git
  Package.swift                           ← manifesto SÓ-CI (biblioteca pura + testes)
  Tests/CadernoCoreTests/*.swift          ← testes unitários (rodam no CI com `swift test`)
  .github/workflows/ci.yml                ← GitHub Actions
  README.md  .gitignore  GUIA-GITHUB.md
  CadernoApp.swiftpm/                      ← projeto que abre no Swift Playgrounds
    Package.swift                          ← manifesto de App (AppleProductTypes)
    Sources/
      CadernoCore/*.swift                  ← MESMOS arquivos-fonte referenciados pelo Package.swift SÓ-CI
      AppModule/*.swift                    ← casca de App (SwiftUI + PencilKit + UIKit)
```

Ponto crítico: `CadernoCore` é a ÚNICA cópia da lógica. O `Package.swift` da raiz aponta
seu target para `CadernoApp.swiftpm/Sources/CadernoCore` via `path:`. Assim o CI testa
exatamente o mesmo código que roda no iPad, sem duplicação e sem dependência remota.

## Regra de ouro do CadernoCore

`CadernoCore` importa **APENAS Foundation**. NUNCA UIKit, SwiftUI, PencilKit, Combine.
O desenho de uma página é tratado como `Data` opaco (bytes) — o Core não sabe que é um
PKDrawing. Isso deixa o CI compilar/testar o Core em qualquer runner, sem simulador.

Datas: `JSONEncoder`/`JSONDecoder` com `.dateEncodingStrategy = .iso8601` e
`.outputFormatting = [.prettyPrinted, .sortedKeys]` — arquivos legíveis para recuperação
manual (filosofia Obsidian). Toda escrita em disco é ATÔMICA (temp + replace) e nunca
reescreve o caderno inteiro; só o arquivo alterado.

## Formato do pacote `.caderno`

```
MeuCaderno.caderno/
  manifest.json
  pages/<id>.drawing        ← bytes opacos (será PKDrawing.dataRepresentation())
  pages/<id>.json           ← PageMeta (metadados da página)
  assets/                   ← criado vazio na fase 0
  index/text.json           ← criado vazio/placeholder na fase 0
  .trash/<id>/              ← página apagada (retém 30 dias) + os arquivos movidos
  .trash/trash.json         ← [TrashEntry]
```

## API pública do CadernoCore (implemente exatamente)

```swift
import Foundation

public enum CadernoSchema {
    public static let current: Int = 1
}

public struct Manifest: Codable, Equatable {
    public var schemaVersion: Int
    public var notebookID: String     // UUID().uuidString
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pageOrder: [String]    // ids na ordem de exibição
    public init(schemaVersion: Int, notebookID: String, title: String,
                createdAt: Date, updatedAt: Date, pageOrder: [String])
}

public struct PageMeta: Codable, Equatable {
    public var id: String             // UUID().uuidString, == nome do arquivo
    public var createdAt: Date
    public var updatedAt: Date
    public var template: String       // "blank","ruled","grid","dotted","cornell"
    public init(id: String, createdAt: Date, updatedAt: Date, template: String)
}

public struct TrashEntry: Codable, Equatable {
    public var id: String
    public var deletedAt: Date
    public var originalIndex: Int
    public init(id: String, deletedAt: Date, originalIndex: Int)
}

public enum CadernoError: Error, Equatable {
    case notFound(String)
    case corruptManifest
    case integrityFailed(String)
    case unsupportedSchema(Int)
    case io(String)
}

public final class NotebookStore {
    public let packageURL: URL
    public init(packageURL: URL)

    /// Cria um novo pacote .caderno dentro de parentDirectory, com 1 página em branco.
    public static func create(at parentDirectory: URL, title: String) throws -> NotebookStore

    /// Abre um pacote existente; roda migração se schemaVersion < current.
    public static func open(packageURL: URL) throws -> NotebookStore

    public func loadManifest() throws -> Manifest
    public func pages() throws -> [PageMeta]                 // na ordem de manifest.pageOrder
    public func pageMeta(id: String) throws -> PageMeta

    @discardableResult
    public func addPage(template: String) throws -> PageMeta // acrescenta ao fim

    public func deletePage(id: String) throws                // move para .trash (não apaga)
    public func restorePage(id: String) throws               // volta do .trash na posição original (ou fim)
    public func purgeTrash(olderThan days: Int) throws       // remove definitivamente > N dias
    public func movePage(id: String, toIndex: Int) throws

    public func readDrawing(pageID: String) throws -> Data?  // nil se página sem traço ainda
    public func writeDrawing(_ data: Data, pageID: String) throws // atômico; atualiza updatedAt

    public func verifyIntegrity() throws                     // pageOrder x arquivos presentes
}

public enum Migrator {
    /// Identidade na v1, mas estruturado para o futuro (switch em schemaVersion).
    public static func migrate(_ manifest: Manifest) throws -> Manifest
}
```

Sugestão de arquivos do Core (o agente A decide o corte fino, mantendo os nomes acima):
`Manifest.swift`, `PageMeta.swift`, `NotebookStore.swift`, `Migrator.swift`,
`Trash.swift`, `CadernoError.swift`, `JSON.swift` (encoder/decoder configurados).

## Casca de App — AppModule (SwiftUI + PencilKit + UIKit)

Tipos que a casca expõe (agentes C e D devem bater exatamente):

- `AppState` (ObservableObject) — dono do `NotebookStore` atual e do id da página aberta.
  Criado pelo agente C. Campos mínimos:
  ```swift
  @MainActor final class AppState: ObservableObject {
      @Published var store: NotebookStore
      @Published var currentPageID: String
      let backup: BackupManager        // injetado
      init(store: NotebookStore, currentPageID: String, backup: BackupManager)
  }
  ```
- `BackupManager` (ObservableObject) — criado pelo agente D. Assinatura fixa:
  ```swift
  @MainActor final class BackupManager: ObservableObject {
      enum SyncStatus: Equatable { case noFolder, idle, syncing, synced(Date), failed(String) }
      @Published private(set) var status: SyncStatus
      init()
      func chooseFolder(presenting: UIViewController)   // UIDocumentPicker de pasta
      func hasFolder() -> Bool
      func mirror(package: URL)                          // espelha o .caderno na pasta escolhida
      func exportFallback(package: URL)                  // plano B: cópia ao ir para background
  }
  ```
- `PenDiagnosticView` (SwiftUI View) — criado pelo agente D. `init()` sem parâmetros.
  Mostra ao vivo: `UITouch.type` (.pencil?), `force`/`maximumPossibleForce` (pressão
  detectada?), `altitudeAngle`/`azimuthAngle` (inclinação?), e estimativa de taxa de
  amostragem (via `coalescedTouches`/timestamps). Termina com um VEREDITO em texto:
  "Pressão: detectada/ausente → espessura por pressão/velocidade" e "Inclinação:
  detectada/ausente".

Componentes que o agente C cria:
- `CadernoApp.swift` — `@main struct CadernoApp: App`. No launch: acha/cria
  `MeuCaderno.caderno` em `.documentDirectory` (via `NotebookStore.open` senão `.create`),
  monta `AppState` e `BackupManager`, injeta como `@StateObject`/`environmentObject`.
- `PKCanvasRepresentable.swift` — `UIViewRepresentable` de `PKCanvasView` + `PKToolPicker`.
  `drawingPolicy` configurável (default `.pencilOnly`). No `canvasViewDrawingDidChange`,
  salva `canvasView.drawing.dataRepresentation()` via `store.writeDrawing` com DEBOUNCE
  ~0.4s e FORA da main thread; depois chama `backup.mirror(package:)`. Carga inicial:
  `try? PKDrawing(data:)` a partir de `store.readDrawing`.
- `RootView.swift` — canvas da página atual ocupando a tela; barra superior fina com:
  (1) `BackupStatusView` sempre visível, (2) botão engrenagem que abre `PenDiagnosticView`
  em sheet, (3) seletor de `drawingPolicy` (3 opções: automático/só caneta/qualquer toque).
- `BackupStatusView.swift` — pílula pequena ligada a `BackupManager.status` (verde=synced,
  amarelo=syncing, vermelho=failed, cinza=noFolder). Criado pelo agente C.

Regra: nenhuma perda silenciosa. Se `mirror` falhar, `status = .failed(msg)` e a pílula
fica vermelha. Salvamento local (camada 1) SEMPRE acontece antes do espelhamento.

## Package.swift SÓ-CI (raiz) — agente E

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CadernoCore",
    products: [ .library(name: "CadernoCore", targets: ["CadernoCore"]) ],
    targets: [
        .target(name: "CadernoCore", path: "CadernoApp.swiftpm/Sources/CadernoCore"),
        .testTarget(name: "CadernoCoreTests",
                    dependencies: ["CadernoCore"],
                    path: "Tests/CadernoCoreTests")
    ]
)
```

## Package.swift do App (.swiftpm) — agente E

Manifesto `.iOSApplication` com AppleProductTypes. SEM capabilities na fase 0 (evita o
crash histórico de microfone; câmera/mic/fala só na fase 4). Dois targets: a lib
`CadernoCore` e o app `AppModule` que depende dela. Família de dispositivo: `.pad`.
Use um template correto de `.iOSApplication` (bundleIdentifier `br.pessoal.caderno`,
displayVersion "0.1", bundleVersion "1", accentColor opcional, sem appIcon custom).

## CI — agente E

`.github/workflows/ci.yml`: em `macos-14`, seleciona Xcode recente, roda
`swift test` na raiz (compila e testa o CadernoCore — este é o portão de qualidade).
Opcionalmente, um job SEPARADO best-effort (continue-on-error) que roda `xcodebuild`
sobre o `.swiftpm` como smoke test do manifesto de App
(`CODE_SIGNING_ALLOWED=NO`, `-destination 'generic/platform=iOS'`). O portão que
bloqueia é só o `swift test`.

## GUIA-GITHUB.md — agente E

Passo a passo para uma pessoa que NÃO programa: criar conta grátis no GitHub, criar um
repositório PÚBLICO (só código, nunca anotações), subir a pasta pelo site (arrastar
arquivos), e como ler o resultado da CI (o ✓ verde ou o ✗ vermelho na aba Actions).
Linguagem simples, sem jargão. Nada de linha de comando obrigatória.
