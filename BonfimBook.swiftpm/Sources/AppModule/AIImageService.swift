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
        let english = await translateToEnglish(base) ?? base
        let full = english + ", " + style

        // Codifica o texto para caber no caminho da URL (sem "/", "?", "#").
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encoded = full.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlString = "https://image.pollinations.ai/prompt/\(encoded)"
            + "?width=\(size)&height=\(size)&model=flux&nologo=true"

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

    /// Resposta do MyMemory (tradutor grátis, sem chave).
    private struct MyMemoryResponse: Decodable {
        struct ResponseData: Decodable { let translatedText: String }
        let responseData: ResponseData
    }

    /// Traduz o texto de português para inglês usando o MyMemory (grátis, sem cadastro). O
    /// modelo de imagem entende MUITO melhor em inglês; traduzir aqui é o que faz "coroa de
    /// rei" virar uma coroa de verdade. Retorna nil se falhar (aí seguimos com o original).
    private static func translateToEnglish(_ text: String) async -> String? {
        guard !text.isEmpty else { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))
        guard let q = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.mymemory.translated.net/get?q=\(q)&langpair=pt%7Cen") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(MyMemoryResponse.self, from: data) else {
            return nil
        }
        let translated = decoded.responseData.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return translated.isEmpty ? nil : translated
    }
}

