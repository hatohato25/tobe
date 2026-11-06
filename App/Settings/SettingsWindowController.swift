import AppKit
import Observation
import SwiftUI

/// 設定画面のウィンドウ（`NSWindow` + `NSHostingView`。design.md 12.4、D-24）。
///
/// 使い方（T54）:
/// ```swift
/// let settingsWindow = SettingsWindowController(model: settingsModel)
/// hotkey.statusItem.onOpenSettings = { [weak settingsWindow] in settingsWindow?.show() }
/// ```
///
/// - ウィンドウは使い回す。閉じても解放せず、`show()` で同じウィンドウを前面に出す。
/// - 閉じた状態から開くたびに、入力欄の下書きを保存済みの値に戻す（`SettingsView.sessionID`）。
/// - ログイン時の起動の状態は保存しないので、開いたときと、表示中にアプリがアクティブになったときに読み直す（S-4.2）。
///   システム設定で外してから Tobe に戻ると、トグルの表示が実態に追従する。
///
/// スレッド: MainActor でだけ使う。
@MainActor
final class SettingsWindowController: NSObject {
    private let model: SettingsModel
    private let launchAtLogin: LaunchAtLoginModel
    private let window: NSWindow
    private let hostingView: NSHostingView<SettingsView>

    /// ウィンドウが画面に出ているか。
    var isVisible: Bool {
        window.isVisible
    }

    init(model: SettingsModel) {
        self.model = model
        let launchAtLogin = LaunchAtLoginModel(service: LaunchAtLoginService())
        self.launchAtLogin = launchAtLogin
        hostingView = NSHostingView(
            rootView: SettingsView(model: model, launchAtLogin: launchAtLogin, sessionID: UUID())
        )
        window = SettingsWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()

        window.title = String(localized: "Tobe Settings", comment: "Settings: window title")
        // 閉じても使い回す（メニューの「設定…」から何度でも開く）
        window.isReleasedWhenClosed = false
        // ユーザーがいま見ている Space に出す
        window.collectionBehavior = [.moveToActiveSpace]
        // NSHostingView の既定の sizingOptions で、ウィンドウの大きさが SwiftUI の内容に合わせて変わる
        window.contentView = hostingView

        // セレクタ方式で登録する。通知は NSApp がメインスレッドで送るので、MainActor のメソッドで受けてよい。
        // macOS 10.11 以降は、解放時に登録を外さなくてよい
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// 設定画面を閉じる（`SettingsModule.stop()` から呼ぶ）。表示していなければ何もしない。
    /// ウィンドウは使い回すので解放しない（`isReleasedWhenClosed = false`）。
    func close() {
        guard window.isVisible else { return }
        window.close()
    }

    /// 設定画面を前面に出す（S-0.1）。表示中なら、そのまま前面に出す（入力中の下書きは残す）。
    func show() {
        if !window.isVisible {
            // 前回閉じたときの入力欄の下書きと検証エラーを捨て、保存済みの値から始める
            hostingView.rootView = SettingsView(model: model, launchAtLogin: launchAtLogin, sessionID: UUID())
            window.center()
        }
        launchAtLogin.refresh()
        // Tobe は LSUIElement のアプリで、ふだんはアクティブにならない。ほかのアプリの後ろに隠れないよう、
        // アプリをアクティブにしてから前面に出す
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // activate() は協調的で、前面のアプリの状況によっては見送られることがある。その場合でも
        // ウィンドウだけは前面に出す
        window.orderFrontRegardless()
        Log.settings.notice("設定画面を表示した")
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        // 閉じている間は読まない（次に開くときに show() が読む）
        guard window.isVisible else { return }
        launchAtLogin.refresh()
    }
}

/// 設定画面のウィンドウ。編集のキー操作（⌘X / ⌘C / ⌘V / ⌘A / ⌘Z）と ⌘W を受ける。
///
/// Tobe は LSUIElement のアプリでメインメニューを持たない。macOS はこれらのキー操作をメインメニューの
/// 「編集」の項目で処理するため、メニューがないと文字セットの欄でコピーや貼り付けができない。
/// ここで同じアクションをレスポンダチェーンに送る。
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let action = Self.action(for: event.charactersIgnoringModifiers, modifiers: modifiers),
            NSApp.sendAction(action, to: nil, from: self)
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func action(for characters: String?, modifiers: NSEvent.ModifierFlags) -> Selector? {
        switch (characters, modifiers) {
        case ("x", .command): #selector(NSText.cut(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("v", .command): #selector(NSText.paste(_:))
        case ("a", .command): #selector(NSResponder.selectAll(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        case ("w", .command): #selector(NSWindow.performClose(_:))
        default: nil
        }
    }
}

// MARK: - ログイン時の起動の状態

/// ログイン時の起動の操作（`LaunchAtLoginService` の形）。
///
/// 設定画面のプレビューで `SMAppService` を呼ばずに各状態を出すために抽象化する。アプリでは `LaunchAtLoginService` を使う。
@MainActor
protocol LaunchAtLoginControlling {
    func status() throws(LaunchAtLoginError) -> LaunchAtLoginStatus
    func enable() throws(LaunchAtLoginError) -> LaunchAtLoginStatus
    func disable() throws(LaunchAtLoginError) -> LaunchAtLoginStatus
    func openSystemSettingsLoginItems()
}

extension LaunchAtLoginService: LaunchAtLoginControlling {}

/// 設定画面に出す、ログイン時の起動の状態（S-4.1〜S-4.4、design.md 12.3）。
///
/// - 状態は保存しない。`refresh()` で毎回サービスから読む（D-22）。`SettingsWindowController` が、画面を開いたときと
///   アプリがアクティブになったときに呼ぶ（S-4.2。システム設定で外されたときに表示を追従させる）。
/// - 表示は操作の戻り値の状態で決める（`register()` が成功しても `.requiresApproval` になりうるため）。
/// - 失敗のログは `LaunchAtLoginService` が出すので、ここでは画面に出す文だけを持つ（S-4.4）。
@MainActor
@Observable
final class LaunchAtLoginModel {
    /// 直近に読めた状態。まだ読んでいないか、状態を読めなかったときは `nil`（トグルはオフに見える）。
    private(set) var status: LaunchAtLoginStatus?
    /// 直近の操作または読み取りが失敗したときの、画面に出す文。成功すると `nil` に戻る。
    private(set) var failureMessage: String?
    /// オンにしようとしてサービスが見つからなかったか。未登録のアプリでも `.notFound` が返るので、状態だけではエラーと判断しない。
    private(set) var turnOnFoundNoService = false

    @ObservationIgnored private let service: any LaunchAtLoginControlling

    init(service: any LaunchAtLoginControlling) {
        self.service = service
    }

    /// トグルをオンに見せるか。承認待ち（`.requiresApproval`）は登録済みなのでオンに見せ、承認の案内を添える。
    var isOn: Bool {
        switch status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound, nil: false
        }
    }

    /// 状態をサービスから読み直す。
    func refresh() {
        apply { () throws(LaunchAtLoginError) in try service.status() }
    }

    /// ログイン時に起動するように登録する（S-4.1）。
    func turnOn() {
        apply { () throws(LaunchAtLoginError) in try service.enable() }
        turnOnFoundNoService = status == .notFound
    }

    /// ログイン時の起動の登録を解除する（S-4.1）。
    func turnOff() {
        apply { () throws(LaunchAtLoginError) in try service.disable() }
        turnOnFoundNoService = false
    }

    /// システム設定の「ログイン項目」を開く（S-4.3）。
    func openSystemSettingsLoginItems() {
        service.openSystemSettingsLoginItems()
    }

    private func apply(_ operation: () throws(LaunchAtLoginError) -> LaunchAtLoginStatus) {
        do throws(LaunchAtLoginError) {
            status = try operation()
            failureMessage = nil
        } catch {
            failureMessage = Self.message(for: error)
            // 操作が失敗しても、登録の状態は変わっていることがある。表示を実態に合わせるため読み直す。
            // 読み直しも失敗したときは、直前の状態の表示を残す（最初の失敗の文を上書きしない。
            // 読み直しの失敗は LaunchAtLoginService がログに出す）
            if let current = try? service.status() {
                status = current
            }
        }
    }

    private static func message(for error: LaunchAtLoginError) -> String {
        switch error {
        case .unknownStatus:
            String(
                localized: "Couldn't read the Open at Login status.",
                comment: "Settings: the login item status had an unknown value"
            )
        case .registerFailed(let failure):
            String(
                localized: "Couldn't turn on Open at Login: \(failure.localizedDescription)",
                comment: "Settings: registering the login item failed. The argument is the system's error message"
            )
        case .unregisterFailed(let failure):
            String(
                localized: "Couldn't turn off Open at Login: \(failure.localizedDescription)",
                comment: "Settings: unregistering the login item failed. The argument is the system's error message"
            )
        }
    }
}
