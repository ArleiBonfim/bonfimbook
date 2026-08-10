import SwiftUI

/// Pílula pequena que reflete o `BackupManager.status`.
/// Verde = salvo, amarelo = salvando, vermelho = falha, cinza = sem pasta escolhida.
struct BackupStatusView: View {
    @EnvironmentObject private var backup: BackupManager

    var body: some View {
        let style = Self.style(for: backup.status)
        HStack(spacing: 6) {
            Circle()
                .fill(style.color)
                .frame(width: 8, height: 8)
            Text(style.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(style.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(style.color.opacity(0.15))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Estado do backup: \(style.text)")
    }

    // MARK: - Mapeamento status → cor + texto

    private struct Style {
        let color: Color
        let text: String
    }

    private static func style(for status: BackupManager.SyncStatus) -> Style {
        switch status {
        case .synced(let date):
            return Style(color: .green, text: "Salvo \(timeFormatter.string(from: date))")
        case .syncing:
            return Style(color: .yellow, text: "Salvando…")
        case .failed:
            return Style(color: .red, text: "Falha no backup")
        case .noFolder, .idle:
            return Style(color: .gray, text: "Escolher pasta")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
