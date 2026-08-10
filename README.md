# BonfimBook

App de anotação manuscrita para iPad (Apple Pencil), escrito em Swift. Zero dependências
de terceiros. Alvo: iPadOS. Fase 0.

Filosofia de dados no estilo Obsidian: cada caderno é um pacote `.caderno` com arquivos
legíveis (JSON com chaves ordenadas e datas ISO-8601), gravação atômica e nunca reescrita
do caderno inteiro — apenas do arquivo alterado. Recuperação manual sempre possível.

## Arquitetura em 2 camadas

O código vive em uma única cópia, consumido por dois manifestos diferentes:

```
BonfimBook/                              ← raiz do repo
  Package.swift                          ← manifesto SÓ-CI (biblioteca pura + testes)
  Tests/CadernoCoreTests/                ← testes unitários (rodam no CI)
  .github/workflows/ci.yml               ← compila e testa na nuvem
  BonfimBook.swiftpm/                    ← abre no Swift Playgrounds (iPad) e no Xcode
    Package.swift                        ← manifesto de App (.iOSApplication)
    Sources/
      CadernoCore/                       ← lógica pura — SÓ Foundation
      AppModule/                         ← casca: SwiftUI + PencilKit + UIKit
```

- **Camada 1 — `CadernoCore`**: modelo e persistência (Manifest, PageMeta, Trash,
  `NotebookStore`, `Migrator`). Importa **apenas Foundation**. Não sabe o que é um desenho:
  trata o traço da página como `Data` opaco. Por ser pura, compila e roda em qualquer
  runner de CI, sem simulador.
- **Camada 2 — `AppModule`**: interface e integração com o hardware — canvas PencilKit,
  `PKToolPicker`, backup para pasta escolhida pelo usuário, diagnóstico da caneta. Depende
  de `CadernoCore`.

O `Package.swift` da raiz aponta seu alvo, via `path:`, para
`BonfimBook.swiftpm/Sources/CadernoCore`. Assim o CI testa exatamente o mesmo código que
roda no iPad, sem duplicar arquivos.

## Rodar os testes (requer um Mac com Xcode)

Na raiz do repositório:

```sh
swift test
```

Isso usa o `Package.swift` SÓ-CI, compila o `CadernoCore` e roda os testes unitários. É o
mesmo comando que o GitHub Actions executa a cada push — o resultado aparece na aba
**Actions** do repositório (✓ verde = passou, ✗ vermelho = falhou).

> Sem Mac? Tudo bem. O código foi escrito para ser validado pela CI na nuvem. Veja
> `GUIA-GITHUB.md` para subir o projeto e ler o resultado sem usar terminal.

## Abrir o app no iPad (Swift Playgrounds)

1. Baixe a pasta `BonfimBook.swiftpm` para o iPad (ver `GUIA-GITHUB.md`).
2. Toque nela: o **Swift Playgrounds** (grátis na App Store) reconhece o `.swiftpm` como um
   projeto de App e o abre.
3. Toque em **Executar** (▶) para rodar no próprio iPad. Não é preciso conta paga de
   desenvolvedor para testar localmente.

Também é possível abrir `BonfimBook.swiftpm` diretamente no Xcode em um Mac.

## Estado atual (Fase 0)

- Núcleo de persistência (`CadernoCore`) com pacote `.caderno`, lixeira de 30 dias e
  migração versionada.
- Casca do app com canvas de tinta, backup espelhado e uma tela de diagnóstico da Apple
  Pencil (pressão / inclinação / taxa de amostragem).
- Sem câmera, microfone ou reconhecimento de fala nesta fase.
