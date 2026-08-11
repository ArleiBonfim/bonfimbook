import SwiftUI
import UIKit

/// Mostra o texto organizado pela IA, com opções de copiar ou criar uma página nova com ele.
struct OrganizeResultView: View {
    let text: String
    /// Chamado quando o usuário quer transformar o resultado numa página de texto.
    var onCreatePage: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "(vazio)" : text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Anotação organizada")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copiar", systemImage: "doc.on.doc")
                    }
                    Button {
                        onCreatePage(text)
                        dismiss()
                    } label: {
                        Label("Criar página", systemImage: "doc.badge.plus")
                    }
                }
            }
        }
    }
}
