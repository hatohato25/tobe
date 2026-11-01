/// メニューバーのステータスアイテムと設定画面を担当するモジュール。
///
/// T3 の時点では空の実装。`statusItem`、`settingsProvider` などと、設定の変更を
/// `HotkeyModule` / `HintModeModule` に伝える処理は T54 が足す。
@MainActor
final class SettingsModule: AppModule {
    private let hotkey: HotkeyModule
    private let hintMode: HintModeModule

    init(hotkey: HotkeyModule, hintMode: HintModeModule) {
        self.hotkey = hotkey
        self.hintMode = hintMode
    }

    func start() throws {}

    func stop() {}
}
