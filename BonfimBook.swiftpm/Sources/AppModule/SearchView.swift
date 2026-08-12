import SwiftUI
import PencilKit
import CadernoCore

/// Busca dentro do caderno — inclusive na LETRA à mão (usa o reconhecimento de texto do
/// próprio iPad, o mesmo do "organizar"). Mostra em quais páginas o termo aparece e leva até
/// lá com um toque. Reconhecer a letra de todas as páginas é pesado, então roda fora da main
/// thread com um aviso de progresso.
struct SearchView: View {
    let store: NotebookStore
    let pages: [PageMeta]
    var onOpen: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    @State private var query = ""
    @State private var results: [Hit] = []
    @State private var searching = false
    @State private var searched = false

    struct Hit: Identifiable {
        let id = UUID()
        let page: Int
        let snippet: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                content
            }
            .navigationTitle("Buscar na anotação")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar palavra (também na sua letra)", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled(true)
                .onSubmit { Task { await runSearch() } }
            if !query.isEmpty {
                Button { query = ""; results = []; searched = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if searching {
            VStack(spacing: 12) {
                ProgressView()
                Text("Lendo sua letra nas páginas…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searched && results.isEmpty {
            emptyResult
        } else if results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Digite uma palavra e toque em buscar.").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(results) { hit in
                Button {
                    onOpen(hit.page)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Página \(hit.page + 1)").font(.headline)
                        Text(hit.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyResult: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Nada encontrado para \u{201C}\(query)\u{201D}.").font(.subheadline).foregroundStyle(.secondary)
            Text("A leitura da letra à mão é aproximada — tente outra palavra.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Busca

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searching = true
        searched = false
        results = []
        let snapshot = pages
        let store = self.store

        let hits = await Task.detached(priority: .userInitiated) { () -> [Hit] in
            var found: [Hit] = []
            for (i, page) in snapshot.enumerated() {
                let text = Self.pageText(page, store: store)
                if let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                    found.append(Hit(page: i, snippet: Self.snippet(text, around: r)))
                }
            }
            return found
        }.value

        results = hits
        searching = false
        searched = true
    }

    /// Junta o texto digitado (caixas de texto) e o reconhecido da letra de uma página.
    private static func pageText(_ page: PageMeta, store: NotebookStore) -> String {
        var parts: [String] = []
        if let els = page.elements {
            for e in els where e.kind == .text {
                if let t = e.text, !t.isEmpty { parts.append(t) }
            }
        }
        if let data = try? store.readDrawing(pageID: page.id),
           let drawing = try? PKDrawing(data: data) {
            let b = drawing.bounds
            if b.width > 0, b.height > 0 {
                let ocr = OCRService.recognizeText(in: drawing.image(from: b, scale: 2))
                if !ocr.isEmpty { parts.append(ocr) }
            }
        }
        return parts.joined(separator: " ")
    }

    /// Trecho curto do texto em volta do que casou, com reticências.
    private static func snippet(_ text: String, around r: Range<String.Index>) -> String {
        let lo = text.index(r.lowerBound, offsetBy: -28, limitedBy: text.startIndex) ?? text.startIndex
        let hi = text.index(r.upperBound, offsetBy: 28, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines)
        if lo > text.startIndex { s = "…" + s }
        if hi < text.endIndex { s += "…" }
        return s
    }
}
