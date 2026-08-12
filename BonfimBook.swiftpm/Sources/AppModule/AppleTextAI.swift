import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// IA de TEXTO no próprio iPad (privada) usando o Foundation Models da Apple — o "mini-ChatGPT"
/// que roda offline nos aparelhos com Apple Intelligence + iPadOS 26.
///
/// Tudo protegido por `#if canImport(FoundationModels)`: em versões/aparelhos sem o framework
/// (incluindo o Mac do teste automático), este código "some" na compilação e `available` é
/// falso — o app cai na opção online. Onde existe, arruma o texto sem enviar nada pra fora.
enum AppleTextAI {

    /// true se o Foundation Models existe neste build/versão do sistema.
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return true } else { return false }
        #else
        return false
        #endif
    }

    /// Arruma/organiza o texto no dispositivo. Lança se indisponível.
    static func organize(_ text: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let prompt =
            "Reestruture e alinhe as anotacoes abaixo (portugues do Brasil), SEM reescrever nem "
            + "resumir. Mantenha EXATAMENTE as mesmas palavras e informacoes; apenas organize o "
            + "layout: separe em titulos e topicos com marcadores, agrupe itens relacionados, "
            + "arrume espacamento, quebras de linha e pontuacao. Nao invente conteudo, nao "
            + "explique, nao mude o sentido. Responda apenas com as anotacoes reorganizadas.\n\n" + text
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return response.content
        }
        #endif
        throw NSError(domain: "AppleTextAI", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "IA no dispositivo indisponível neste iPad."])
    }
}
