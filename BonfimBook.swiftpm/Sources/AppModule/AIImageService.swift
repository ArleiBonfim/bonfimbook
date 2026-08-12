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
                         style: String = "detailed vector sticker illustration, vibrant colors, thick clean outline, soft shadow, high quality, centered, white background",
                         size: Int = 1024) async throws -> Data {
        // O modelo entende MUITO melhor em inglês. Traduzimos/reescrevemos o pedido do usuário
        // (que pode estar em português) para um prompt curto em inglês antes de gerar. Se a
        // tradução falhar, seguimos com o texto original (pior caso, mas ainda funciona).
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let english = await translateToEnglish(base) ?? base
        let full = english + ", " + style

        // Codifica o texto para caber no caminho da URL (sem "/", "?", "#").
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encoded = full.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        // enhance=true: o próprio servidor EXPANDE o pedido com uma IA antes de gerar (ex.:
        // "star" vira uma descrição rica de estrela). Como agora a tradução é confiável, isso
        // dá o "contexto maior" que melhora bastante o resultado, sem inventar coisa errada.
        let urlString = "https://image.pollinations.ai/prompt/\(encoded)"
            + "?width=\(size)&height=\(size)&model=flux&nologo=true&enhance=true"

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

    /// Traduz o texto de português para inglês usando o endpoint público do Google Tradutor
    /// (grátis, sem cadastro). É bem mais confiável que o tradutor anterior — que chegou a
    /// devolver "star smiley" para "estrela" e estragava a imagem. O modelo de imagem entende
    /// MUITO melhor em inglês; traduzir aqui é o que faz "estrela" virar uma estrela de verdade.
    /// Retorna nil se falhar (aí seguimos com o texto original).
    ///
    /// A resposta é um array aninhado de JSON: `[[["star","estrela",...], ...], ...]`. Juntamos
    /// todos os pedaços traduzidos (posição [0][i][0]) para cobrir frases com mais de um trecho.
    private static func translateToEnglish(_ text: String) async -> String? {
        guard !text.isEmpty else { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))
        guard let q = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=pt&tl=en&dt=t&q=\(q)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [Any] else {
            return nil
        }
        var result = ""
        for sentence in sentences {
            if let pair = sentence as? [Any], let piece = pair.first as? String {
                result += piece
            }
        }
        let translated = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return translated.isEmpty ? nil : translated
    }
}

