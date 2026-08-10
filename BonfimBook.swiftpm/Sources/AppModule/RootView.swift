import SwiftUI
import PencilKit

/// Tela principal: o canvas da página atual ocupa a tela inteira, com uma barra
/// superior fina para estado de backup, seletor de entrada e diagnóstico da caneta.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var backup: BackupManager

    @State private var drawingPolicy: PKCanvasViewDrawingPolicy = .pencilOnly
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            PKCanvasRepresentable(
                store: appState.store,
                backup: backup,
                pageID: appState.currentPageID,
                drawingPolicy: $drawingPolicy
            )
            // Recria o canvas ao trocar de página, garantindo a carga inicial correta
            // e descartando qualquer debounce da página anterior.
            .id(appState.currentPageID)
        }
        .sheet(isPresented: $showDiagnostics) {
            PenDiagnosticView()
        }
    }

    // MARK: - Barra superior

    private var topBar: some View {
        HStack(spacing: 12) {
            BackupStatusView()

            Spacer()

            Picker("Entrada", selection: $drawingPolicy) {
                Text("Automático").tag(PKCanvasViewDrawingPolicy.default)
                Text("Só caneta").tag(PKCanvasViewDrawingPolicy.pencilOnly)
                Text("Qualquer toque").tag(PKCanvasViewDrawingPolicy.anyInput)
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Button {
                showDiagnostics = true
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.large)
            }
            .accessibilityLabel("Diagnóstico da caneta")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
