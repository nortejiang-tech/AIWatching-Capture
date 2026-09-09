import SwiftUI
import UIKit

enum AIWatchingColor {
    static var brand: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 76.0 / 255.0, green: 175.0 / 255.0, blue: 142.0 / 255.0, alpha: 1)
                : UIColor(red: 13.0 / 255.0, green: 107.0 / 255.0, blue: 80.0 / 255.0, alpha: 1)
            }
        )
    }

    static var recording: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 255.0 / 255.0, green: 99.0 / 255.0, blue: 99.0 / 255.0, alpha: 1)
                : UIColor(red: 198.0 / 255.0, green: 40.0 / 255.0, blue: 40.0 / 255.0, alpha: 1)
            }
        )
    }

    static var onAccent: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 21.0 / 255.0, green: 23.0 / 255.0, blue: 26.0 / 255.0, alpha: 1)
                : UIColor(red: 247.0 / 255.0, green: 248.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
            }
        )
    }

    static var warning: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 244.0 / 255.0, green: 181.0 / 255.0, blue: 79.0 / 255.0, alpha: 1)
                : UIColor(red: 154.0 / 255.0, green: 90.0 / 255.0, blue: 24.0 / 255.0, alpha: 1)
            }
        )
    }

    static var danger: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 242.0 / 255.0, green: 115.0 / 255.0, blue: 115.0 / 255.0, alpha: 1)
                : UIColor(red: 163.0 / 255.0, green: 59.0 / 255.0, blue: 49.0 / 255.0, alpha: 1)
            }
        )
    }

    static var paper: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 21.0 / 255.0, green: 23.0 / 255.0, blue: 26.0 / 255.0, alpha: 1)
                : UIColor(red: 246.0 / 255.0, green: 243.0 / 255.0, blue: 238.0 / 255.0, alpha: 1)
            }
        )
    }

    static var card: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 39.0 / 255.0, green: 45.0 / 255.0, blue: 51.0 / 255.0, alpha: 1)
                : UIColor(red: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0, alpha: 1)
            }
        )
    }

    static var ink: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 234.0 / 255.0, green: 236.0 / 255.0, blue: 240.0 / 255.0, alpha: 1)
                : UIColor(red: 31.0 / 255.0, green: 33.0 / 255.0, blue: 36.0 / 255.0, alpha: 1)
            }
        )
    }

    static var muted: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                ? UIColor(red: 156.0 / 255.0, green: 163.0 / 255.0, blue: 175.0 / 255.0, alpha: 1)
                : UIColor(red: 107.0 / 255.0, green: 114.0 / 255.0, blue: 128.0 / 255.0, alpha: 1)
            }
        )
    }
}

enum PrivacyChipLevel {
    case localOnly
    case iCloudSyncing
    case externalExport

    var title: String {
        switch self {
        case .localOnly:
            "本机"
        case .iCloudSyncing:
            "iCloud 同步中"
        case .externalExport:
            "外发（显式授权）"
        }
    }

    var icon: String {
        switch self {
        case .localOnly:
            "lock.fill"
        case .iCloudSyncing:
            "arrow.clockwise.icloud"
        case .externalExport:
            "square.and.arrow.up.fill"
        }
    }

    var tint: Color {
        switch self {
        case .localOnly:
            AIWatchingColor.brand
        case .iCloudSyncing:
            AIWatchingColor.warning
        case .externalExport:
            AIWatchingColor.warning
        }
    }

    var detail: String {
        switch self {
        case .localOnly:
            "录音保留在本机"
        case .iCloudSyncing:
            "文件正在云端同步"
        case .externalExport:
            "当前流程需要显式授权"
        }
    }
}

struct PrivacyChip: View {
    let level: PrivacyChipLevel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: level.icon)
                .font(.caption.weight(.bold))
            Text(level.title)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(level.tint)
        .background(
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(AIWatchingColor.card.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .stroke(level.tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(level.title)
        .accessibilityValue(level.detail)
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    private var actionLabel: String {
        isRecording ? "结束捕捉" : "开始捕捉"
    }

    private var iconName: String {
        isRecording ? "stop.fill" : "record.circle.fill"
    }

    private var backgroundColor: Color {
        isRecording ? AIWatchingColor.recording : AIWatchingColor.brand
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 104, height: 104)
                    .overlay(
                        Image(systemName: iconName)
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(AIWatchingColor.onAccent)
                    )

                Text(actionLabel)
                    .font(.body.weight(.bold))
                    .foregroundStyle(backgroundColor)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 2)
        .buttonStyle(.plain)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isRecording ? "录制中" : "空闲")
        .accessibilityHint(isRecording ? "弹出结束捕捉确认" : "开始一次录音捕捉")
    }
}

enum MessageBannerKind {
    case info
    case success
    case warning
    case error

    var icon: String {
        switch self {
        case .info:
            "info.circle"
        case .success:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.circle.fill"
        case .error:
            "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:
            AIWatchingColor.muted
        case .success:
            AIWatchingColor.brand
        case .warning:
            AIWatchingColor.warning
        case .error:
            AIWatchingColor.danger
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .info:
            "提示"
        case .success:
            "成功"
        case .warning:
            "提醒"
        case .error:
            "错误"
        }
    }
}

struct MessageBanner: View {
    let kind: MessageBannerKind
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.icon)
                .font(.title3)
                .foregroundStyle(kind.tint)
                .accessibilityHidden(true)

            Text(message)
                .font(.body)
                .foregroundStyle(AIWatchingColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AIWatchingColor.card.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(kind.tint.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(kind.accessibilityLabel)
        .accessibilityValue(message)
    }
}
