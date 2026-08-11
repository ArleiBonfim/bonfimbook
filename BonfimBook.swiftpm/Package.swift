// swift-tools-version: 5.9

// MANIFESTO DE APP do Swift Playgrounds (.swiftpm).
// Este é o arquivo que o Swift Playgrounds (iPad) e o Xcode abrem para montar o app.
// Ele usa AppleProductTypes + o produto .iOSApplication, que só existe dentro de um
// pacote .swiftpm — por isso o `swift test` da raiz NÃO usa este manifesto.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "BonfimBook",
    // Versão mínima do iPadOS. SEM esta linha o compilador assume um sistema muito
    // antigo (anterior ao iOS 13) e reclama que @Published/ObservableObject "não
    // existem", derrubando toda a compilação em cascata. iOS 16 cobre todas as APIs
    // usadas na fase 0 e mantém compatibilidade ampla de iPad.
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .iOSApplication(
            name: "BonfimBook",
            // O produto é montado a partir do alvo do app (AppModule).
            targets: ["AppModule"],
            bundleIdentifier: "br.pessoal.bonfimbook",
            // teamIdentifier omitido de propósito: rodar no próprio iPad via
            // Swift Playgrounds não exige conta paga; o Playgrounds preenche a assinatura.
            displayVersion: "0.1",
            bundleVersion: "1",
            // SEM appIcon custom nesta fase (nenhum iconAssetName).
            // accentColor presetado (opcional) — cor de destaque da UI, sem asset catalog.
            accentColor: .presetColor(.indigo),
            supportedDeviceFamilies: [
                .pad
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeLeft,
                .landscapeRight
            ],
            // CÂMERA: necessária só para "Digitalizar documento" (scanner). A permissão é
            // pedida ao ABRIR o scanner, não no launch — logo não afeta a inicialização do
            // app. NÃO declaramos microfone/fala (foi o que causou crash histórico); só a
            // câmera, com uma frase de propósito clara ao usuário.
            capabilities: [
                .camera(purposeString: "Usada para digitalizar documentos direto para o seu caderno.")
            ]
        )
    ],
    targets: [
        // Biblioteca pura, a MESMA testada pela CI. Só Foundation.
        .target(
            name: "CadernoCore",
            path: "Sources/CadernoCore"
        ),
        // Casca do app (SwiftUI + PencilKit + UIKit), com o @main App.
        // ESCOLHA: usamos `.executableTarget`, não `.target`. Na sintaxe atual do Swift
        // Playgrounds (swift-tools-version 5.9), o alvo listado em
        // `.iOSApplication(targets: [...])` precisa ser um alvo executável — é ele que
        // contém o ponto de entrada `@main`. Um `.target` (biblioteca) não produziria um
        // executável e o Playgrounds recusaria o produto de App.
        .executableTarget(
            name: "AppModule",
            dependencies: ["CadernoCore"],
            path: "Sources/AppModule"
        )
    ]
)
