import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red, green, blue, alpha: Double
        switch cleaned.count {
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        default:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

struct AiGoBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "0A1024"),
                    Color(hex: "111A35"),
                    Color(hex: "16132B")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(hex: "6E7BFF").opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 30,
                endRadius: 650
            )
            RadialGradient(
                colors: [Color(hex: "14B8A6").opacity(0.12), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 540
            )
        }
        .ignoresSafeArea()
    }
}

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var emphasized: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(emphasized ? Color.white.opacity(0.045) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(emphasized ? 0.18 : 0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 18, emphasized: Bool = false) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, emphasized: emphasized))
    }
}

struct ModelBadge: View {
    var modelID: String = "Codex CLI"
    var effort: ReasoningEffort?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
            Text(modelID.isEmpty ? "CLI 默认模型" : modelID)
            if let effort {
                Text("· \(effort.title)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(hex: "6E7BFF").opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(Color(hex: "8B96FF").opacity(0.32)))
    }
}

struct RunStatusBadge: View {
    let phase: RunPhase

    private var color: Color {
        switch phase {
        case .idle: return .secondary
        case .running: return Color(hex: "38BDF8")
        case .awaitingApproval: return Color(hex: "F59E0B")
        case .completed: return Color(hex: "22C55E")
        case .failed: return Color(hex: "F43F5E")
        case .cancelled: return Color(hex: "94A3B8")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(phase.title)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
    }
}
