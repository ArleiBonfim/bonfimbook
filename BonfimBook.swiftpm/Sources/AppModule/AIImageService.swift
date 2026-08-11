import Foundation
import UIKit

/// Geração de imagem por um serviço GRÁTIS e sem cadastro (Pollinations.ai). Funciona em
/// qualquer iPad (só precisa de internet). Recebe um texto e devolve os bytes de uma imagem.
///
/// PRIVACIDADE: o texto do pedido é enviado ao servidor do Pollinations (é um serviço
/// externo). O usuário escolhe usar esta opção conscientemente; a outra opção (Apple Image
/// Playground) roda no próprio aparelho, sem enviar nada.
enum AIImageService {

    enum AIError: LocalizedError {
        case badURL
        case badResponse
        case notAnImage

        var errorDescription: String? {
            switch self {
            case .badURL: return "Não consegui montar o pedido da imagem."
            case .badResponse: return "O serviço de imagem não respondeu direito. Tente de novo."
            case .notAnImage: return "O que voltou não era uma imagem válida."
            }
        }
    }

    /// Gera uma imagem a partir de `prompt` (grátis, sem chave). `style` é acrescentado ao
    /// texto para empurrar o resultado para um visual de desenho/clipart.
    ///
    /// Qualidade/acerto: usamos `enhance=true` (a Pollinations melhora/expande o pedido com
    /// uma IA antes de gerar — resolve muito o "saiu nada a ver") e o modelo `flux` (o de
    /// melhor qualidade), em resolução 1024.
    static func generate(prompt: String,
                         style: String = "in the style of a simple, cute, flat clipart illustration, clean bold lines, minimal, high quality",
                         size: Int = 1024) async throws -> Data {
        // O modelo entende MUITO melhor em inglês. Traduzimos/reescrevemos o pedido do usuário
        // (que pode estar em português) para um prompt curto em inglês antes de gerar. Se a
        // tradução falhar, seguimos com o texto original (pior caso, mas ainda funciona).
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let english = await toEnglishImagePrompt(base) ?? base
        let full = english + ", " + style

        // Codifica o texto para caber no caminho da URL (sem "/", "?", "#").
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encoded = full.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlString = "https://image.pollinations.ai/prompt/\(encoded)"
            + "?width=\(size)&height=\(size)&model=flux&enhance=true&nologo=true"

        guard let url = URL(string: urlString) else { throw AIError.badURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 90   // a geração pode demorar alguns segundos

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError.badResponse
        }
        guard UIImage(data: data) != nil else { throw AIError.notAnImage }
        return data
    }

    /// Usa o serviço grátis de TEXTO para traduzir/reescrever o pedido (ex.: "coroa de rei")
    /// num prompt curto em inglês ("a golden king's crown, ..."). Retorna nil se falhar.
    private static func toEnglishImagePrompt(_ text: String) async -> String? {
        guard !text.isEmpty else { return nil }
        let instruction =
        "Translate and rewrite the following into a short English prompt to generate a simple, "
        + "cute, flat clipart illustration. Reply with ONLY the prompt, no quotes, no explanation.\n\n"
        + text

        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let encoded = instruction.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://text.pollinations.ai/\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Limpa aspas/linhas extras que o modelo às vezes devolve.
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        // Se veio vazio ou absurdamente longo (erro do serviço), descarta.
        guard !cleaned.isEmpty, cleaned.count < 400 else { return nil }
        return cleaned
    }
}

