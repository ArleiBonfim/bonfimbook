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
    static func generate(prompt: String,
                         style: String = "simple flat clipart, cartoon, clean lines, white background",
                         size: Int = 768) async throws -> Data {
        let full = prompt.trimmingCharacters(in: .whitespacesAndNewlines) + ", " + style

        // Codifica o texto para caber no caminho da URL (sem "/", "?", "#").
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encoded = full.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlString = "https://image.pollinations.ai/prompt/\(encoded)?width=\(size)&height=\(size)&nologo=true"

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
}
