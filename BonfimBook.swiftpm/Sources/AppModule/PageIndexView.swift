import SwiftUI
import CadernoCore

/// Índice do caderno: lista as páginas (número + nome, se tiver) e leva até a página com um
/// toque. As favoritas aparecem com estrela. É a navegação rápida estilo "sumário".
struct PageIndexView: View {
    let pages: [PageMeta]
    var onOpen: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if pages.isEmpty {
                    Text("Sem páginas.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(Array(pages.enumerated()), id: \.element.id) { pair in
                        Button {
                            onOpen(pair.offset)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(pair.offset + 1)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .leading)
                                Text(pair.element.title ?? "Página \(pair.offset + 1)")
                                    .foregroundStyle(pair.element.title == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                Spacer()
                                if pair.element.favorite == true {
                                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Índice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
    }
}
