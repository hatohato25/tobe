/// ヒントモード（要素の収集、ラベル表示、入力の絞り込み、操作の実行）を担当するモジュール。
///
/// T3 の時点では空の実装。`HotkeyModule` が公開する値（タップのイベントなど）を使う処理は T48 が足す。
@MainActor
final class HintModeModule: AppModule {
    private let hotkey: HotkeyModule

    init(hotkey: HotkeyModule) {
        self.hotkey = hotkey
    }

    func start() throws {}

    func stop() {}
}
