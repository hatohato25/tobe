import TobiCore

/// 設定（`SettingsModel`）と設定画面（`SettingsWindowController`）を担当し、設定の値をほかのモジュールに結ぶモジュール。
///
/// - 起動キー: 設定画面での変更は `SettingsModel` の `applyTriggerKey` からイベントタップに届く（S-1.1）。
///   起動時の保存値は `start()` で反映する（`HotkeyModule` はこのモジュールより先に固定値でタップを作るため）。
/// - ヒントモードの設定: `hintMode.settingsProvider` を `SettingsModel` の値に差し替える。
///   Coordinator は単独タップのたびにこれを読むので、変更は次のヒントモードから効く（S-0.4）。
/// - 起動時の読み込みの問題（`SettingsIssue`）: `SettingsModel` がログに出し、設定画面が上部に表示する（S-0.3）。
///   設定画面は自動では開かない。起動のたびにウィンドウが前面に出ると作業を妨げるうえ、
///   問題の項目には既定値が使われていて動作は続けられるため。
@MainActor
final class SettingsModule: AppModule {
    private let hotkey: HotkeyModule
    private let hintMode: HintModeModule
    private let model: SettingsModel
    private let settingsWindow: SettingsWindowController

    init(hotkey: HotkeyModule, hintMode: HintModeModule) {
        self.hotkey = hotkey
        self.hintMode = hintMode
        let eventTap = hotkey.eventTap
        // 読み込み（と問題のログ）はここで 1 回だけ行う
        let model = SettingsModel(
            store: UserDefaultsSettingsStore(defaults: .standard),
            applyTriggerKey: { [eventTap] in eventTap.updateTriggerKey($0) }
        )
        self.model = model
        settingsWindow = SettingsWindowController(model: model)
    }

    func start() {
        applyLaunchTriggerKey()
        hintMode.settingsProvider = { [model] in model.settings }
        hotkey.statusItem.onOpenSettings = { [weak settingsWindow] in settingsWindow?.show() }
        if !model.loadIssues.isEmpty {
            // 個々の問題は SettingsModel がログに出している。ここでは件数と、どこで確認できるかだけを残す
            Log.settings.notice(
                "保存された設定の一部を読めなかったため既定値を使う（\(self.model.loadIssues.count, privacy: .public) 件）。設定画面に表示する"
            )
        }
        Log.app.notice("SettingsModule を開始した")
    }

    func stop() {
        hotkey.statusItem.onOpenSettings = nil
        settingsWindow.close()
    }

    /// 保存された起動キーをイベントタップに反映する。
    ///
    /// Debug ビルドで `--trigger-key` が指定されているときは反映しない。`EventTapController` の生成時に
    /// その値が使われており、設定より優先する（T38 の手動確認で、保存値に関係なくキーを固定するため）。
    private func applyLaunchTriggerKey() {
        #if DEBUG
            if let debugTriggerKey = EventTapDebugHooks.options.triggerKey {
                Log.settings.notice(
                    "--trigger-key が指定されているため、保存された起動キーは使わない（\(debugTriggerKey.rawValue, privacy: .public)）"
                )
                return
            }
        #endif
        hotkey.eventTap.updateTriggerKey(model.settings.triggerKey)
    }
}
