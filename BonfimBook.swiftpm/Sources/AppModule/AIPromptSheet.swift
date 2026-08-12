import SwiftUI

/// Telinha para descrever a imagem a ser gerada. Substitui o antigo "alerta com campo de
/// texto", que no iPad às vezes não abria o teclado e chegou a travar o app (o AutoFill de
/// senha tentava se anexar ao campo). Numa sheet o teclado é confiável e focamos o campo na
/// hora, com AutoFill/autocorreção desligados.
struct AIPromptSheet: View {
    @Binding var text: String
    var onGenerate: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Descreva em poucas palavras o que quer desenhar. Sai em estilo desenho/clipart.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("ex.: um gato astronauta", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .textContentType(.none)          // evita o AutoFill de senha que travava
                    .autocorrectionDisabled(true)
                    .submitLabel(.go)
                    .onSubmit(generate)

                Spacer()
            }
            .padding(20)
            .navigationTitle("Gerar imagem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gerar", action: generate)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            // Foca o campo (abre o teclado) assim que a tela aparece.
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220)])
    }

    private func generate() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismiss()
        onGenerate()
    }
}
