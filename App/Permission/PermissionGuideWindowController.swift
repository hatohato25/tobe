import AppKit
import SwiftUI

/// アクセシビリティ権限の案内画面のウィンドウ（`NSWindow` + `NSHostingView`。design.md 4 章・11 章）。
///
/// 使い方:
/// ```swift
/// let guide = PermissionGuideWindowController()
/// guide.show(state: .notGranted)       // 前面に出す
/// guide.state = .tapCreationFailed     // 表示中の内容だけを切り替える
/// guide.close()
/// ```
///
/// - 「システム設定を開く」は、`AXIsProcessTrustedWithOptions` のプロンプトを 1 回出してから
///   「プライバシーとセキュリティ > アクセシビリティ」を開く（N-3.2）。権限の確認そのものは `PermissionMonitor` が行う。
/// - 許可されたときに閉じる、タップの作成に失敗したら `.tapCreationFailed` にする、といった結線は T37 が行う。
///
/// スレッド: MainActor でだけ使う。
@MainActor
final class PermissionGuideWindowController: NSObject, NSWindowDelegate {
    private static let accessibilitySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    private let model: PermissionGuideModel
    private let window: NSWindow

    /// ウィンドウが閉じられたとき（ユーザーの操作と `close()` のどちらでも）に呼ばれる。
    var onClose: (@MainActor () -> Void)?

    /// 表示する状態。表示中に書き換えると、その場で表示が切り替わる。
    var state: PermissionGuideState {
        get { model.state }
        set { model.state = newValue }
    }

    /// ウィンドウが画面に出ているか。
    var isVisible: Bool {
        window.isVisible
    }

    override init() {
        let model = PermissionGuideModel(state: .notGranted)
        self.model = model
        window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()

        window.title = String(localized: "Tobi", comment: "Permission guide: window title")
        // 閉じても使い回す（再び未許可になったときに同じウィンドウを出す）
        window.isReleasedWhenClosed = false
        // ユーザーがいま見ている Space に出す
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        // NSHostingView の既定の sizingOptions で、ウィンドウの大きさが SwiftUI の内容に合わせて変わる
        window.contentView = NSHostingView(
            rootView: PermissionGuideView(
                model: model,
                openSettings: { [weak self] in self?.openSystemSettings() },
                close: { [weak self] in self?.close() }
            )
        )
    }

    /// 状態を設定して、案内画面を前面に出す（N-3.1、N-3.4）。
    func show(state: PermissionGuideState) {
        self.state = state
        if !window.isVisible {
            window.center()
        }
        // Tobi は LSUIElement のアプリで、ふだんはアクティブにならない。ほかのアプリの後ろに隠れないよう、
        // アプリをアクティブにしてから前面に出す
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // activate() は協調的で、前面のアプリの状況によっては見送られることがある。その場合でも
        // ウィンドウだけは前面に出す
        window.orderFrontRegardless()
        Log.permission.notice("案内画面を表示した: \(String(describing: state), privacy: .public)")
    }

    /// 案内画面を閉じる。表示していなければ何もしない。
    func close() {
        guard window.isVisible else { return }
        window.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        Log.permission.info("案内画面を閉じた")
        onClose?()
    }

    // MARK: - ボタン

    private func openSystemSettings() {
        // アクセシビリティの一覧に Tobi を載せるため、プロンプト付きの確認を 1 回呼ぶ（design.md 11 章）。
        // kAXTrustedCheckOptionPrompt はグローバル変数で Swift 6 の並行性の検査に掛かるため、キーは文字列で書く
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Log.permission.notice("AXIsProcessTrustedWithOptions(prompt) = \(trusted, privacy: .public)")

        guard let url = URL(string: Self.accessibilitySettingsURL) else {
            Log.permission.error("システム設定の URL を作れなかった")
            return
        }
        if !NSWorkspace.shared.open(url) {
            Log.permission.error("システム設定のアクセシビリティの画面を開けなかった")
        }
    }
}
