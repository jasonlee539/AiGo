import AppKit
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
        Color(hex: "17191C")
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
                    .fill(Color(hex: emphasized ? "24272B" : "202327"))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(emphasized ? Color.white.opacity(0.012) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(emphasized ? 0.10 : 0.065), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.16), radius: 8, y: 3)
    }
}

struct AppBrandIcon: View {
    private var image: NSImage? {
        let candidates = [
            Bundle.main.url(forResource: "tray-icon", withExtension: "png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("src/tray-icon.png")
        ]
        return candidates.compactMap { $0 }.compactMap(NSImage.init(contentsOf:)).first
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("AiGo")
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
            Image(systemName: "terminal")
            Text(modelID.isEmpty ? "CLI 默认模型" : modelID)
            if let effort {
                Text("· \(effort.title)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .padding(.horizontal, 1)
        .foregroundStyle(.secondary)
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
