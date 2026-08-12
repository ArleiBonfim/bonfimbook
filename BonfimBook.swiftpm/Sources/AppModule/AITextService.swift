import Foundation

/// Organização/ajuste de texto por um serviço GRÁTIS e sem cadastro (Pollinations.ai).
/// Funciona em qualquer iPad (precisa de internet).
///
/// PRIVACIDADE: o texto é enviado ao servidor do Pollinations. É a opção "online"; a opção
/// no próprio iPad (Apple) fica em `AppleTextAI` e não envia nada pra fora.
enum AITextService {

    enum AIError: LocalizedError {
        case badURL
        case badResponse
        var errorDescription: String? {
            switch self {
            case .badURL: return "Não consegui montar o pedido."
            case .badResponse: return "O serviço de texto não respondeu direito. Tente de novo."
            }
        }
    }

    /// Devolve o texto arrumado/organizado. Limita o tamanho enviado para caber na requisição.
    static func organize(_ text: String) async throws -> String {
        let capped = String(text.prefix(1800))
        let instruction =
        "Reestruture e alinhe as anotacoes abaixo (portugues do Brasil), SEM reescrever nem "
        + "resumir. Mantenha EXATAMENTE as mesmas palavras e informacoes; apenas organize o "
        + "layout: separe em titulos e topicos com marcadores, agrupe itens relacionados, "
        + "arrume espacamento, quebras de linha e pontuacao. Nao invente conteudo, nao explique, "
        + "nao mude o sentido. Responda apenas com as anotacoes reorganizadas.\n\n" + capped

        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encoded = instruction.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard let url = URL(string: "https://text.pollinations.ai/\(encoded)") else {
            throw AIError.badURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 90

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw AIError.badResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
