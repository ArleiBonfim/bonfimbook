// swift-tools-version: 5.9
import PackageDescription

// MANIFESTO SÓ-CI (raiz do repo).
// Este arquivo existe apenas para o GitHub Actions rodar `swift test` num runner
// macOS SEM abrir simulador. Ele compila e testa APENAS a biblioteca pura CadernoCore,
// que importa somente Foundation. Não há aqui nenhum alvo de App, UIKit, SwiftUI ou
// PencilKit — por isso `swift test` funciona sem AppleProductTypes.
//
// Ponto crítico: o alvo aponta, via `path:`, para a ÚNICA cópia da lógica, que mora
// dentro do projeto do iPad (BonfimBook.swiftpm/Sources/CadernoCore). Assim o CI testa
// exatamente o mesmo código que roda no iPad, sem duplicar arquivos.
let package = Package(
    name: "CadernoCore",
    products: [
        .library(name: "CadernoCore", targets: ["CadernoCore"])
    ],
    targets: [
        .target(
            name: "CadernoCore",
            path: "BonfimBook.swiftpm/Sources/CadernoCore"
        ),
        .testTarget(
            name: "CadernoCoreTests",
            dependencies: ["CadernoCore"],
            path: "Tests/CadernoCoreTests"
        )
    ]
)
