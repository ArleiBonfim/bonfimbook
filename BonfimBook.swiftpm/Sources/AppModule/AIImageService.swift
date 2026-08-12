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
    /// Estratégia de QUALIDADE: tenta primeiro o modelo **FLUX** (num espaço público da
    /// Hugging Face, sem cadastro) — muito mais nítido. Se ele estiver ocupado/indisponível,
    /// cai no Pollinations ("sana", mais simples) como reserva. Sempre devolve PNG.
    static func generate(prompt: String,
                         style: String = "flat vector illustration, clean simple shapes, solid colors, bold outline, sticker, plain white background",
                         size: Int = 1024) async throws -> Data {
        // O modelo entende MUITO melhor em inglês; traduzimos o pedido antes de gerar.
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let english = await translateToEnglish(base) ?? base
        let full = english + ", " + style

        // 1ª opção: FLUX (nítido). Qualquer falha → cai no Pollinations.
        let raw: Data
        if let flux = try? await generateFlux(prompt: full) {
            raw = flux
        } else {
            raw = try await generatePollinations(prompt: full, size: size)
        }

        // Normaliza para PNG (o FLUX volta em webp) para gravar/desenhar sempre igual.
        if let image = UIImage(data: raw), let png = image.pngData() {
            return png
        }
        guard UIImage(data: raw) != nil else { throw AIError.notAnImage }
        return raw
    }

    // MARK: - FLUX (Hugging Face, sem cadastro) — melhor qualidade

    private static let fluxInfer = "https://black-forest-labs-flux-1-schnell.hf.space/gradio_api/call/infer"

    /// Gera pelo FLUX.1-schnell num Space público (API do Gradio, 2 passos: pede → busca o
    /// resultado no fluxo de eventos → baixa a imagem). Sem chave. Pode falhar se o Space
    /// estiver ocupado (cota anônima) — aí quem chama usa o Pollinations.
    private static func generateFlux(prompt: String) async throws -> Data {
        // Passo 1: POST com os parâmetros [texto, semente, sortear_semente, largura, altura, passos].
        guard let postURL = URL(string: fluxInfer) else { throw AIError.badURL }
        var post = URLRequest(url: postURL)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.timeoutInterval = 30
        let body: [String: Any] = ["data": [prompt, 0, true, 1024, 1024, 4]]
        post.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (d1, r1) = try await URLSession.shared.data(for: post)
        guard let h1 = r1 as? HTTPURLResponse, (200..<300).contains(h1.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let eventID = obj["event_id"] as? String else {
            throw AIError.badResponse
        }

        // Passo 2: GET o fluxo de eventos; ele fecha quando termina, trazendo a URL da imagem.
        guard let getURL = URL(string: fluxInfer + "/" + eventID) else { throw AIError.badURL }
        var get = URLRequest(url: getURL)
        get.timeoutInterval = 120   // pode entrar numa fila
        let (d2, r2) = try await URLSession.shared.data(for: get)
        guard let h2 = r2 as? HTTPURLResponse, (200..<300).contains(h2.statusCode),
              let text = String(data: d2, encoding: .utf8),
              let urlString = extractURL(from: text),
              let imageURL = URL(string: urlString) else {
            throw AIError.badResponse
        }

        // Passo 3: baixa a imagem (webp).
        let (imgData, r3) = try await URLSession.shared.data(from: imageURL)
        guard let h3 = r3 as? HTTPURLResponse, (200..<300).contains(h3.statusCode),
              UIImage(data: imgData) != nil else {
            throw AIError.notAnImage
        }
        return imgData
    }

    /// Extrai a primeira `"url": "…"` do fluxo de eventos do Gradio (a imagem gerada).
    private static func extractURL(from text: String) -> String? {
        guard let key = text.range(of: "\"url\":") else { return nil }
        let afterKey = text[key.upperBound...]
        guard let open = afterKey.range(of: "\"") else { return nil }
        let afterOpen = afterKey[open.upperBound...]
        guard let close = afterOpen.range(of: "\"") else { return nil }
        return String(afterOpen[..<close.lowerBound])
    }

    // MARK: - Pollinations (reserva)

    private static func generatePollinations(prompt: String, size: Int) async throws -> Data {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encoded = prompt.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let seed = Int.random(in: 0...9_999_999)
        let urlString = "https://image.pollinations.ai/prompt/\(encoded)"
            + "?width=\(size)&height=\(size)&model=flux&nologo=true&seed=\(seed)"
        guard let url = URL(string: urlString) else { throw AIError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
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

