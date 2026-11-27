import NanoPandaCore
import SwiftUI

enum WorkspaceStyle {
    static let ink = color(0x111827)
    static let secondary = color(0x4B5563)
    static let muted = color(0x6B7280)
    static let sidebar = color(0xF7F8FA)
    static let neutral = color(0xF3F4F6)
    static let inset = color(0xF9FAFB)
    static let border = color(0xE5E7EB)
    static let strongBorder = color(0xD1D5DB)
    static let blue = color(0x2563EB)
    static let blueTint = color(0xEFF6FF)
    static let blueBorder = color(0xBFDBFE)
    static let green = color(0x10B981)
    static let greenTint = color(0xECFDF5)
    static let greenInk = color(0x005236)
    static let amber = color(0xF59E0B)
    static let amberTint = color(0xFFEEDE)
    static let amberInk = color(0x653E00)
    static let red = color(0xBA1A1A)
    static let redTint = color(0xFFEDEA)
    static let headline = Font.system(size: 22, weight: .semibold)
    static let section = Font.system(size: 16, weight: .semibold)
    static let title = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 12)
    static let mono = Font.system(size: 12, design: .monospaced)

    static func color(_ rgb: UInt32) -> Color {
        Color(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    static func dot(_ status: SyncStatus) -> Color {
        switch status {
        case .synced: return green
        case .pending, .drift: return amber
        case .unavailable: return red
        case .missing: return strongBorder
        }
    }

    static func tone(_ status: SyncStatus) -> (fill: Color, ink: Color) {
        switch status {
        case .synced: return (greenTint, greenInk)
        case .pending, .drift: return (amberTint, amberInk)
        case .unavailable: return (redTint, red)
        case .missing: return (neutral, secondary)
        }
    }
}

struct WorkspaceButton: ButtonStyle {
    enum Kind { case normal, primary, quiet, danger }
    var kind = Kind.normal
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .foregroundStyle(kind == .primary ? .white : kind == .danger ? WorkspaceStyle.red : WorkspaceStyle.ink)
            .background(kind == .primary ? WorkspaceStyle.blue : kind == .quiet ? .clear : .white, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(kind == .primary || kind == .quiet ? .clear : WorkspaceStyle.border)
            }
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct WorkspaceSegments<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var equalWidth = false
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 25)
                        .frame(maxWidth: equalWidth ? .infinity : nil)
                        .foregroundStyle(option == selection ? WorkspaceStyle.blue : WorkspaceStyle.secondary)
                        .background(option == selection ? .white : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(option == selection ? WorkspaceStyle.border : .clear) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .padding(3)
        .background(WorkspaceStyle.neutral, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(WorkspaceStyle.border) }
    }
}

struct FormatBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(WorkspaceStyle.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(WorkspaceStyle.border) }
            .fixedSize()
    }
}

struct WorkspaceStatus: View {
    let status: SyncStatus
    var filled = true

    var body: some View {
        let tone = WorkspaceStyle.tone(status)
        HStack(spacing: 5) {
            Circle().fill(WorkspaceStyle.dot(status)).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(status.rawValue).font(.system(size: 11, weight: .medium))
        }
        .fixedSize()
        .padding(.horizontal, filled ? 7 : 0).padding(.vertical, 3)
        .foregroundStyle(filled ? tone.ink : WorkspaceStyle.secondary)
        .background(filled ? tone.fill : .clear, in: Capsule())
    }
}

extension View {
    func workspaceCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.border) }
    }

    func workspaceField() -> some View {
        self.font(WorkspaceStyle.mono)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(WorkspaceStyle.border) }
    }
}

extension ToolID {
    static let workspaceOrder: [ToolID] = [.claudeCode, .codex, .antigravity, .cursor, .windsurf, .claudeDesktop, .geminiCLI, .openCode]

    var formatLabel: String {
        switch self {
        case .codex: return "TOML"
        case .openCode: return "JSONC"
        default: return "JSON"
        }
    }
}

extension Transport {
    var formatLabel: String {
        switch self {
        case .stdio: return "STDIO"
        case .http: return "HTTP"
        case .sse: return "SSE"
        }
    }
}


struct PandaMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 24
            func spot(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color) {
                let rect = CGRect(x: (x - width / 2) * scale, y: (y - height / 2) * scale,
                                  width: width * scale, height: height * scale)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
            spot(7, 6.5, 5.5, 5.5, .white)
            spot(17, 6.5, 5.5, 5.5, .white)
            spot(12, 13.5, 14, 14, .white)
            spot(9.25, 12.5, 2.8, 2.8, WorkspaceStyle.ink)
            spot(14.75, 12.5, 2.8, 2.8, WorkspaceStyle.ink)
            spot(12, 15.5, 3.2, 2.2, WorkspaceStyle.ink)
        }
        .frame(width: 19, height: 19)
        .frame(width: 28, height: 28)
        .background(WorkspaceStyle.ink, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
