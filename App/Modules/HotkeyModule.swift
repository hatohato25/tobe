import TobiCore

/// 起動キーの検出（CGEventTap）と、それを支える権限の確認・案内画面・ステータスアイテムを担当するモジュール。
///
/// 後続のモジュール（`HintModeModule`・`SettingsModule`）は、コンストラクタで受け取った `hotkey` から
/// 公開プロパティを読む。`PermissionMonitor`・`PermissionGuideWindowController` などは App 全体で 1 つずつにする
/// （T32 の申し送り）ため、ほかのモジュールは自分で作らず、ここのものを使う。
///
/// - タップは自分で作らない。権限の変化を受けて作る・止めるのは `EventTapWatchdog`（T34）。
///   `eventTap.start()` を外から呼ぶと、ウォッチドッグの作成が `.alreadyStarted` になる。
/// - 案内画面の結線: 起動時は `permissionMonitor.status` で出し、その後は `watchdog.events` で開く・閉じる（N-3.1〜N-3.5）。
/// - ステータスアイテムの表示は `permissionMonitor.statusChanges()` で更新する（N-2.3）。
@MainActor
final class HotkeyModule: AppModule {
    /// 起動キー。設定がまだないので右 ⌘ に固定する（T52・T54 で設定から読む）。
    /// Debug ビルドでは `--trigger-key`（`EventTapDebugHooks`）がこれより優先される。
    private static let triggerKey: TriggerKey = .rightCommand

    /// アクセシビリティ権限の確認（App 全体で 1 つ）。
    let permissionMonitor: PermissionMonitor
    /// 権限の案内画面（App 全体で 1 つ）。
    let permissionGuide: PermissionGuideWindowController
    /// イベントタップ。キー破棄の OFF（`setSuppressing(false)`）と起動キーの変更（`updateTriggerKey`）に使う。
    let eventTap: EventTapController
    /// 権限とタップの見張り。タップの作成・停止はこれが行う。
    let watchdog: EventTapWatchdog
    /// メニューバーのステータスアイテム。`onOpenSettings` は T54 の `SettingsModule` が設定する。
    let statusItem: StatusItemController
    /// keyCode → `HintKeyInput` の変換（MainActor）。
    let keyTranslator: KeyTranslator

    /// タップのスレッドからの通知（`eventTap.events`）。購読者は 1 つだけ（今は仮のヒントモード、T48 で Coordinator の結線）。
    var tapEvents: AsyncStream<TapEvent> {
        eventTap.events
    }

    private var watchdogTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?

    init() {
        let permissionMonitor = PermissionMonitor()
        let permissionGuide = PermissionGuideWindowController()
        let eventTap = EventTapController(triggerKey: Self.triggerKey)
        self.permissionMonitor = permissionMonitor
        self.permissionGuide = permissionGuide
        self.eventTap = eventTap
        watchdog = EventTapWatchdog(controller: eventTap, permissionMonitor: permissionMonitor)
        // 生成した時点でメニューバーにアイコンが出る
        statusItem = StatusItemController(permissionGuide: permissionGuide, permission: permissionMonitor.status)
        keyTranslator = KeyTranslator()
    }

    func start() {
        guard watchdogTask == nil else {
            Log.app.fault("HotkeyModule.start() が 2 回呼ばれた。2 回目は何もしない")
            return
        }
        // statusChanges() は購読した後の変化だけを流すので、確認を始める前に購読する
        let permissionChanges = permissionMonitor.statusChanges()
        permissionTask = Task { [weak self] in
            for await status in permissionChanges {
                self?.statusItem.update(permission: status)
            }
        }
        permissionMonitor.start()

        // init から start までの間に変わっていてもよいよう、いまの状態で表示をそろえる
        let status = permissionMonitor.status
        statusItem.update(permission: status)
        switch status {
        case .notGranted:
            // タップはウォッチドッグが許可を待って作る（N-3.1、N-3.3）
            permissionGuide.show(state: .notGranted)
        case .granted:
            break
        }

        // events は生成時から上限なしで溜めるので、watchdog.start() の前に購読していなくても取りこぼさない
        let watchdogEvents = watchdog.events
        watchdogTask = Task { [weak self] in
            for await event in watchdogEvents {
                self?.handle(event)
            }
        }
        // 権限があれば、ここでタップを作る（結果は .tapStarted / .tapStartFailed で届く）
        watchdog.start()
        Log.app.notice("HotkeyModule を開始した（権限: \(String(describing: status), privacy: .public)）")
    }

    func stop() {
        // 逆順にすると、止めたタップをウォッチドッグが 1 秒後に作り直す（T34）
        watchdog.stop()
        eventTap.stop()
        statusItem.remove()
        watchdogTask?.cancel()
        watchdogTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        permissionMonitor.stop()
        permissionGuide.close()
    }

    private func handle(_ event: EventTapWatchdogEvent) {
        switch event {
        case .permissionGranted:
            // 再起動なしで動き始める（N-3.3）。タップの作成はこの後ウォッチドッグが行う
            permissionGuide.close()
        case .permissionRevoked:
            // タップとキー破棄はウォッチドッグが止めてある（N-3.4）
            permissionGuide.show(state: .notGranted)
        case .tapStarted:
            Log.app.info("イベントタップが動き始めた")
        case .tapStartFailed(let error):
            Log.app.error("イベントタップを作れなかった: \(String(describing: error), privacy: .public)")
            permissionGuide.show(state: .tapCreationFailed)
        }
    }
}
