# CONTRATO — BonfimBook, Fase 1+2 (caderno de verdade)

Estende o projeto EXISTENTE (não quebrar o que já compila verde no CI). Alvo iOS 16,
Xcode 15.4 / Swift 5.10. Você NÃO compila no Windows — escreva Swift idiomático, sem rodar
build. O CI valida.

## Gotchas já conhecidos (NÃO reintroduzir)
- `Task` que roda fora da main e mexe em `self`: usar `Task { @MainActor [weak self] in ... }`.
- `try?` sobre função que devolve `T?` já dá `T?` (não fazer duplo `if let`).
- Deployment target iOS 16 já está no Package.swift (`platforms: [.iOS(.v16)]`) — mantê-lo.
- Canvas de escrita: fundo CLARO de papel, nunca `.systemBackground` (fica preto no dark).

## Meta
Transformar a folha em branco num caderno real: **biblioteca de cadernos → caderno com
várias páginas → cada página com estilo de papel (pautado/quadriculado/pontilhado/Cornell/
liso) e as ferramentas da Apple visíveis.**

## Estrutura de navegação nova
`LibraryView` (tela inicial: lista de cadernos) → toca num caderno → `NotebookView` (páginas
do caderno). O app abre na `LibraryView`.

---

## CAMADA CORE (Foundation-only) — extensões

### PaperTemplate.swift (novo)
```swift
public enum PaperTemplate: String, CaseIterable, Codable {
    case blank, ruled, grid, dotted, cornell
    public var displayName: String {
        switch self {
        case .blank: return "Liso"
        case .ruled: return "Pautado"
        case .grid: return "Quadriculado"
        case .dotted: return "Pontilhado"
        case .cornell: return "Cornell"
        }
    }
}
```
`PageMeta.template` (String, já existe) guarda o `rawValue`. Continua String no disco.

### Manifest.swift (editar)
Adicionar campo OPCIONAL (para arquivos antigos continuarem decodificando):
```swift
public var coverColorHex: String?   // cor da capa; nil = padrão
```
Incluir no `init` com default `nil` (parâmetro no fim, `coverColorHex: String? = nil`).
Como é opcional, manifests v1 sem esse campo decodificam com nil — SEM bump de schema.

### NotebookStore.swift (editar)
- `create(at:title:)` → adicionar parâmetro `coverColorHex: String? = nil` (no fim), gravado
  no manifest. Assinatura antiga continua válida por causa do default.
- Novo: `public func setTemplate(_ template: String, pageID: String) throws` — atualiza
  `PageMeta.template` da página + `updatedAt` (atômico, mesmo padrão de writeDrawing).
- Novo: `public func setCoverColor(_ hex: String?) throws` — atualiza manifest.coverColorHex.
- `addPage(template:)` já existe — usar.

### NotebookLibrary.swift (novo, Foundation-only)
```swift
public struct NotebookRef: Equatable {
    public let url: URL
    public let title: String
    public let updatedAt: Date
    public let pageCount: Int
    public let coverColorHex: String?
    public init(url: URL, title: String, updatedAt: Date, pageCount: Int, coverColorHex: String?)
}
public enum NotebookLibrary {
    public static func defaultDirectory() throws -> URL     // .documentDirectory
    /// Todos os *.caderno do diretório, lendo cada manifest; ordena por updatedAt desc.
    public static func list(in directory: URL) throws -> [NotebookRef]
    /// Cria um caderno novo (usa NotebookStore.create) e devolve o store.
    public static func create(in directory: URL, title: String, coverColorHex: String?) throws -> NotebookStore
    /// Move o pacote inteiro para `<dir>/.Lixeira/<nome>-<timestampSeg>` (não apaga de vez).
    public static func moveToTrash(_ url: URL) throws
}
```
`list` deve ser tolerante: se um pacote não abrir, pula (não derruba a lista inteira).

### Testes (CadernoCoreTests) — novos
- PaperTemplate rawValue round-trip + CaseIterable tem 5 casos.
- Manifest decodifica um JSON ANTIGO sem `coverColorHex` → campo vira nil (colar um JSON
  literal representando v1 sem o campo e decodificar).
- NotebookLibrary.create + list: cria 2 cadernos, list devolve 2 refs com pageCount correto
  (1 cada, pois create faz 1 página) e ordenados por updatedAt desc.
- setTemplate persiste (reabre e confere PageMeta.template).

---

## CAMADA APPMODULE (SwiftUI + PencilKit + UIKit)

### PaperBackgroundView.swift (novo) — o conserto visual principal
`struct PaperBackgroundView: View` recebendo `template: PaperTemplate`. Desenha o PAPEL:
- Fundo de papel CLARO sempre (ex.: `Color(red: 0.99, green: 0.99, blue: 0.97)`), NÃO
  depende de dark mode (papel é papel). Sombra/borda sutil opcional.
- Padrão por template, desenhado com `Canvas` (SwiftUI) ou `GeometryReader`+`Path`:
  - `.blank`: só o papel.
  - `.ruled`: linhas horizontais a cada ~34pt, cor sutil (ex.: `Color(red:0.85,green:0.87,blue:0.92)`), com uma linha de margem vertical vermelha clara à esquerda (~44pt).
  - `.grid`: quadriculado ~24pt, mesma cor sutil.
  - `.dotted`: pontos ~24pt de espaçamento, raio ~1pt.
  - `.cornell`: pautado + 1 linha vertical de "dica" a ~28% da largura + faixa de "resumo" na base (~18% da altura) separada por linha horizontal.
Deve preencher o espaço disponível (usar o tamanho do container). Ferramenta puramente
visual, sem estado.

### PKCanvasRepresentable.swift (editar)
- `canvas.backgroundColor = .clear` e `canvas.isOpaque = false` (para o papel aparecer atrás).
- Mantém o salvamento com debounce + backup (já existe). NÃO regredir isso.

### LibraryView.swift (novo) — tela inicial
`struct LibraryView: View` (usar `NavigationStack`). 
- Lista/grade dos cadernos via `NotebookLibrary.list`. Cada item: retângulo "capa" com a cor
  (coverColorHex ou cor padrão), título, "N páginas", data. Toque → navega para `NotebookView`.
- Botão **"Novo caderno"** (＋): cria via `NotebookLibrary.create` (título "Caderno" + número,
  cor de capa sorteada de uma paleta fixa) e abre.
- Estado vazio acolhedor: se não há cadernos, texto "Crie seu primeiro caderno" + botão grande.
- Menu por caderno (context menu / botão): **Apagar** (via `moveToTrash`), **Renomear** (opcional).
- Barra superior: título "BonfimBook", `BackupStatusView()`, botão engrenagem → `PenDiagnosticView` em sheet.
- Recarregar a lista ao voltar de um caderno (onAppear).

### NotebookView.swift (novo) — caderno aberto (substitui o papel da antiga RootView)
`struct NotebookView: View` recebendo o `NotebookStore` (e o `BackupManager` do ambiente).
- Estado: `pages: [PageMeta]`, `currentIndex: Int`, `currentTemplate: PaperTemplate`.
- Área central: `ZStack { PaperBackgroundView(template: currentTemplate); PKCanvasRepresentable(store:backup:pageID:drawingPolicy:) .id(pageAtual.id) }` — canvas transparente sobre o papel.
- Barra inferior: **‹ anterior**, **"Pág. N de M"**, **próxima ›**, **＋ (adicionar página)**,
  **🗑 (apagar página atual, com confirmação)**, botão **miniaturas**.
- Barra superior: **‹ Biblioteca** (volta), menu **"Papel"** listando `PaperTemplate.allCases`
  (troca o template da página atual via `store.setTemplate`, atualiza o fundo na hora),
  seletor de `drawingPolicy` (3 opções), `BackupStatusView()`.
- `PKToolPicker` visível (canetas/marca-texto/lápis/borracha/cores/régua) — já vem do
  `PKCanvasRepresentable`; garanta que aparece.
- Adicionar página: usa o template atual como padrão. Navegar: troca currentIndex e recarrega.
- Ao trocar de página/template, recarregar `pages` de `store.pages()`.

### PageThumbnailsView.swift (novo)
`struct PageThumbnailsView: View` recebendo o store + callback de seleção.
- Grade de miniaturas: para cada página, desenhar uma miniatura = papel do template +
  imagem do traço (`PKDrawing(data: store.readDrawing(pageID:))?.image(from:scale:)` sobre o papel).
  Se ficar pesado/complexo, cair para: cartão com número da página + ícone do template + data.
- Tocar numa miniatura → chama o callback com o índice e fecha.

### AppState.swift (editar) / roteamento
- App abre na `LibraryView`. O `AppState` pode guardar só o `BackupManager` e o diretório da
  biblioteca; o caderno aberto vira estado da navegação (NavigationStack path) ou um
  `@State var openStore: NotebookStore?`. Simplifique: `LibraryView` cria/abre o `NotebookStore`
  e navega para `NotebookView(store:)`.
- Manter `BackupManager` como `@EnvironmentObject` global (injetado no `CadernoApp`).

### CadernoApp.swift (editar) — agente E
- Root = `LibraryView` dentro de `NavigationStack`, com `.environmentObject(backup)`.
- NÃO auto-criar caderno (a biblioteca cuida disso, com estado vazio). Garantir que o
  diretório de Documents existe.
- Remover o uso da antiga `RootView` (o arquivo `RootView.swift` sai de cena; sua função foi
  para `NotebookView`). Se for mais seguro, deixar `RootView.swift` sem `@main` e não referenciá-lo
  (o integrador remove depois) — mas PREFERIR não depender dele.

### ci.yml (editar) — agente E
No job `smoke-app`, trocar o passo de compilar para capturar a saída e **escrever os erros
no resumo do job** (`$GITHUB_STEP_SUMMARY`), para ficarem legíveis sem abrir logs:
```yaml
      - name: Compilar o app e reportar erros no resumo
        working-directory: BonfimBook.swiftpm
        run: |
          set +e
          xcodebuild -scheme BonfimBook -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build > build.log 2>&1
          code=$?
          {
            echo "## smoke-app — compilacao do app (exit $code)"
            echo "### Erros e avisos"
            echo '```'
            grep -E ": error:|: warning:" build.log | sed 's#/Users/runner/work/bonfimbook/bonfimbook/##g' | sort -u | head -100
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
          exit $code
```
Manter o job `test` (swift test) como está.

## Divisão de donos (evitar conflito de arquivos)
- Agente A: SÓ Core — PaperTemplate.swift, NotebookLibrary.swift (novos), edições em
  Manifest.swift e NotebookStore.swift, e testes novos em Tests/CadernoCoreTests.
- Agente B: SÓ PaperBackgroundView.swift (novo) + edição pontual em PKCanvasRepresentable.swift
  (fundo clear/isOpaque).
- Agente C: SÓ LibraryView.swift (novo).
- Agente D: SÓ NotebookView.swift + PageThumbnailsView.swift (novos).
- Agente E: SÓ CadernoApp.swift (editar), AppState.swift (editar), ci.yml (editar).
Cada um usa as assinaturas Core/tipos acima EXATAMENTE. Não redefinir tipos de outro agente.
