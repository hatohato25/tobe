import AppKit

/// メニューバーのステータスアイテムとそのメニュー（design.md 4 章、D-24、N-2.2、N-2.3、S-0.1）。
///
/// メニューの項目は Q-24 の暫定方針に従う。
/// - 「Grant Accessibility Permission…」: 権限が未許可のときだけ出す。押すと案内画面を開く
/// - 「Settings…」: `onOpenSettings` を呼ぶだけ（設定画面との結線は T54 の `SettingsModule`）
/// - 「Quit Tobe」: `NSApp.terminate(nil)`
///
/// 使い方（結線は T37 の `HotkeyModule`）:
/// ```swift
/// let statusItem = StatusItemController(permissionGuide: guide, permission: monitor.status)
/// for await status in monitor.statusChanges() {
///     statusItem.update(permission: status)
/// }
/// ```
///
/// - 生成した時点でメニューバーにアイコンが出る。`remove()` を呼ぶまで出し続ける。
/// - 案内画面のコントローラは App 全体で 1 つのもの（T37 の申し送り）を外から受け取る。
///
/// スレッド: MainActor でだけ使う。
@MainActor
final class StatusItemController: NSObject {
    // SF Symbols の名前。テンプレート画像にしてメニューバーの明暗に合わせる。
    // keyboard.badge.exclamationmark は macOS 27 の SF Symbols に無いため、未許可は警告の三角にする
    private static let grantedSymbol = "keyboard"
    private static let notGrantedSymbol = "exclamationmark.triangle"

    private let statusItem: NSStatusItem
    private let permissionGuide: PermissionGuideWindowController
    private let grantPermissionItem: NSMenuItem
    private let grantPermissionSeparator: NSMenuItem

    /// 「Settings…」を押したときに呼ばれる。未設定のときはログに残すだけで何もしない（T54 が設定する）。
    var onOpenSettings: (@MainActor () -> Void)?

    /// いま表示に反映している権限の状態。
    private(set) var permission: PermissionStatus

    /// ステータスアイテムを作り、メニューバーにアイコンを出す。
    ///
    /// - Parameters:
    ///   - permissionGuide: 「Grant Accessibility Permission…」で開く案内画面。
    ///   - permission: 起動時の権限の状態（`PermissionMonitor.status`）。
    init(permissionGuide: PermissionGuideWindowController, permission: PermissionStatus) {
        self.permissionGuide = permissionGuide
        self.permission = permission
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        grantPermissionItem = NSMenuItem(
            title: String(
                localized: "Grant Accessibility Permission…",
                comment: "Status menu: opens the accessibility permission guide (shown only when not granted)"
            ),
            action: nil,
            keyEquivalent: ""
        )
        grantPermissionSeparator = NSMenuItem.separator()
        super.init()

        // ユーザーが ⌘ ドラッグで動かした位置を、次回の起動でも保てるようにする
        statusItem.autosaveName = "TobeStatusItem"
        statusItem.menu = makeMenu()
        apply(permission: permission)
        Log.app.info("ステータスアイテムを作成した")
    }

    /// 権限の状態を表示に反映する。T37 が `PermissionMonitor.statusChanges()` から呼ぶ。
    func update(permission: PermissionStatus) {
        guard permission != self.permission else { return }
        self.permission = permission
        apply(permission: permission)
    }

    /// メニューバーからアイコンを取り除く。取り除いた後のこのインスタンスは使わない。
    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
        Log.app.info("ステータスアイテムを取り除いた")
    }

    // MARK: - 組み立て

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // 表示・非表示は isHidden で切り替えるため、自動の有効化（validateMenuItem）は使わない
        menu.autoenablesItems = false

        grantPermissionItem.target = self
        grantPermissionItem.action = #selector(grantPermissionSelected)
        menu.addItem(grantPermissionItem)
        menu.addItem(grantPermissionSeparator)

        let settingsItem = NSMenuItem(
            title: String(localized: "Settings…", comment: "Status menu: opens the settings window"),
            action: #selector(settingsSelected),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit Tobe", comment: "Status menu: quits the app"),
            action: #selector(quitSelected),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func apply(permission: PermissionStatus) {
        let isGranted = permission == .granted
        grantPermissionItem.isHidden = isGranted
        grantPermissionSeparator.isHidden = isGranted

        guard let button = statusItem.button else {
            // squareLength で作ったアイテムには常にボタンがある。無ければアイコンを出せないので記録する
            Log.app.error("ステータスアイテムのボタンが無い")
            return
        }
        let symbolName = isGranted ? Self.grantedSymbol : Self.notGrantedSymbol
        let description =
            isGranted
            ? String(localized: "Tobe", comment: "Status item: accessibility description when permission is granted")
            : String(
                localized: "Tobe (Accessibility permission required)",
                comment: "Status item: accessibility description when permission is not granted"
            )
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) {
            // テンプレート画像にすると、メニューバーの明暗（ダークモード・壁紙）に合わせて色が変わる
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            // シンボルが無い OS でもアイテム自体は見えるように文字で出す
            Log.app.error("SF Symbol が見つからない: \(symbolName, privacy: .public)")
            button.image = nil
            button.title = isGranted ? "Tobe" : "Tobe!"
        }
        button.toolTip = description
        Log.app.info("ステータスアイテムの権限表示を更新した: \(String(describing: permission), privacy: .public)")
    }

    // MARK: - メニューの操作

    @objc private func grantPermissionSelected() {
        permissionGuide.show(state: .notGranted)
    }

    @objc private func settingsSelected() {
        guard let onOpenSettings else {
            Log.app.notice("「設定…」が押されたが、設定画面がまだ結ばれていない")
            return
        }
        onOpenSettings()
    }

    @objc private func quitSelected() {
        NSApp.terminate(nil)
    }
}
