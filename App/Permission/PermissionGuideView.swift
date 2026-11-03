import SwiftUI

/// 案内画面に出す状態（design.md 11 章の表）。
enum PermissionGuideState: Sendable, Equatable {
    /// アクセシビリティが未許可（N-3.1、N-3.4）。
    case notGranted
    /// 許可済み（N-3.3）。
    case granted
    /// 許可されているのに、イベントタップを作れなかった（N-3.5）。この状態に切り替えるのは T33・T37。
    case tapCreationFailed
}

/// 案内画面の表示内容。`PermissionGuideWindowController` が持ち、状態を書き換えると表示が切り替わる。
@MainActor
@Observable
final class PermissionGuideModel {
    var state: PermissionGuideState

    init(state: PermissionGuideState) {
        self.state = state
    }
}

/// アクセシビリティ権限の案内画面（N-3.1〜N-3.5）。
///
/// 案内するのはアクセシビリティだけ（V-1。入力監視は要らない）。許可した後の再起動も要らない（V-7）。
/// 文言は `PermissionGuideStrings` に集め、日本語のローカライズは後のタスクで String Catalog に足す。
struct PermissionGuideView: View {
    let model: PermissionGuideModel
    /// 「システム設定を開く」を押したとき。
    let openSettings: @MainActor () -> Void
    /// 「閉じる」を押したとき。
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(PermissionGuideStrings.title)
                .font(.title2)
                .bold()

            statusRow

            VStack(alignment: .leading, spacing: 8) {
                Text(PermissionGuideStrings.reason)
                Text(PermissionGuideStrings.privacy)
                Text(PermissionGuideStrings.noRestart)
            }
            .fixedSize(horizontal: false, vertical: true)

            buttons
        }
        .padding(24)
        .frame(width: 440)
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            Text(statusText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.headline)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch model.state {
            case .notGranted:
                Button(PermissionGuideStrings.openSettings, action: openSettings)
                    .keyboardShortcut(.defaultAction)
            case .granted, .tapCreationFailed:
                Button(PermissionGuideStrings.close, action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var statusText: String {
        switch model.state {
        case .notGranted: PermissionGuideStrings.statusNotGranted
        case .granted: PermissionGuideStrings.statusGranted
        case .tapCreationFailed: PermissionGuideStrings.statusTapCreationFailed
        }
    }

    private var statusSymbol: String {
        switch model.state {
        case .notGranted: "lock.fill"
        case .granted: "checkmark.circle.fill"
        case .tapCreationFailed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .notGranted: .secondary
        case .granted: .green
        case .tapCreationFailed: .orange
        }
    }
}

/// 案内画面の文言。英語を基本にする（Q-24 の暫定方針）。キーは英語の文そのもので、
/// 日本語は後のタスクで String Catalog に訳を足す。
private enum PermissionGuideStrings {
    static let title = String(
        localized: "Accessibility Access for Tobi",
        comment: "Permission guide: window heading"
    )
    static let reason = String(
        localized: """
            Tobi uses Accessibility to find and press buttons in other apps, \
            and to receive the keys you type while hints are shown.
            """,
        comment: "Permission guide: why the permission is needed"
    )
    static let privacy = String(
        localized: "Tobi never records or sends your keystrokes.",
        comment: "Permission guide: privacy statement"
    )
    static let noRestart = String(
        localized: "Once you allow access, Tobi turns on automatically. No restart is needed.",
        comment: "Permission guide: what happens after granting"
    )
    static let statusNotGranted = String(
        localized: "Accessibility access is not allowed yet.",
        comment: "Permission guide: status when not granted"
    )
    static let statusGranted = String(
        localized: "Accessibility access is allowed. Tobi is ready.",
        comment: "Permission guide: status when granted"
    )
    static let statusTapCreationFailed = String(
        localized: "Access is allowed, but Tobi couldn't start listening for the trigger key. Please restart Tobi.",
        comment: "Permission guide: status when the event tap could not be created"
    )
    static let openSettings = String(
        localized: "Open System Settings",
        comment: "Permission guide: button that opens Privacy & Security > Accessibility"
    )
    static let close = String(
        localized: "Close",
        comment: "Permission guide: button that closes the window"
    )
}

#Preview("未許可") {
    PermissionGuideView(model: PermissionGuideModel(state: .notGranted), openSettings: {}, close: {})
}

#Preview("許可済み") {
    PermissionGuideView(model: PermissionGuideModel(state: .granted), openSettings: {}, close: {})
}

#Preview("タップを作れなかった") {
    PermissionGuideView(model: PermissionGuideModel(state: .tapCreationFailed), openSettings: {}, close: {})
}
