import AppKit
import SwiftUI

extension SettingsPage {
    var title: String {
        switch self {
        case .overview: "概览"
        case .general: "通用"
        case .restore: "恢复"
        case .apps: "应用"
        case .layouts: "布局与快照"
        case .permissions: "权限"
        case .diagnostics: "诊断"
        case .log: "活动日志"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .general: "gearshape.fill"
        case .restore: "arrow.uturn.backward"
        case .apps: "square.grid.2x2.fill"
        case .layouts: "rectangle.3.group.fill"
        case .permissions: "lock.shield.fill"
        case .diagnostics: "stethoscope"
        case .log: "list.bullet.rectangle.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .overview: .blue
        case .general: .gray
        case .restore: .green
        case .apps: .orange
        case .layouts: .purple
        case .permissions: .red
        case .diagnostics: .teal
        case .log: .indigo
        case .about: .secondary
        }
    }
}

/// A System Settings style rounded-square icon.
struct BadgeIcon: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

extension AppModel.Phase {
    var tint: Color {
        switch self {
        case .watching: .green
        case .paused: .gray
        case .needsPermission: .orange
        case .settling: .yellow
        case .restoring: .blue
        case .starting: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .watching: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .needsPermission: "exclamationmark.triangle.fill"
        case .settling: "hourglass"
        case .restoring: "arrow.triangle.2.circlepath"
        case .starting: "ellipsis.circle"
        }
    }
}

struct StatusPill: View {
    var phase: AppModel.Phase

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(phase.tint)
                .frame(width: 7, height: 7)
                .shadow(color: phase.tint.opacity(0.6), radius: 3)
            Text(phase.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(phase.tint.opacity(0.14), in: Capsule())
    }
}

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var fillHeight = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label {
                    Text(title).font(.subheadline.weight(.semibold))
                } icon: {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07))
                }
        }
    }
}

/// Uses Liquid Glass button styles where available.
struct AdaptiveButtonStyle: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func adaptiveButton(prominent: Bool = false) -> some View { modifier(AdaptiveButtonStyle(prominent: prominent)) }
}

enum AppIcons {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = image
        return image
    }
}

struct AppIconView: View {
    var bundleID: String
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: AppIcons.icon(for: bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

enum Formatting {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "从未" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 10 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }

    static func size(_ size: CGSize) -> String { "\(Int(size.width))×\(Int(size.height))" }
}

extension DisplayInfo {
    var symbol: String { isBuiltin ? "laptopcomputer" : "display" }
}
