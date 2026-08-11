import SwiftUI
import UIKit

/// Ponte SwiftUI ↔ UIKit para a folha de compartilhamento padrão do sistema
/// (`UIActivityViewController`).
///
/// Uso típico: apresentar via `.sheet` passando os itens a partilhar — por exemplo a URL do
/// PDF gerado por `PDFExporter.makePDF(store:)`. O controlador não guarda estado próprio, então
/// `updateUIViewController` não precisa fazer nada.
struct ShareSheet: UIViewControllerRepresentable {
    /// Itens a compartilhar (URLs de arquivo, textos, imagens...). `Any` porque o
    /// `UIActivityViewController` aceita tipos variados.
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // `applicationActivities: nil` = só as ações padrão do sistema (AirDrop, Arquivos etc.).
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        // Nada a atualizar: os itens são fixados na criação.
    }
}
