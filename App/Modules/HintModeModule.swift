/// ヒントモード（要素の収集、ラベル表示、入力の絞り込み、操作の実行）を担当するモジュール。
///
/// 今は仮の実装（T37）: `hotkey.tapEvents` を `TemporaryHintModeStub` に渡し、F-7（キー破棄）と
/// F-1（起動キー）の手動確認（T38）ができるようにするだけ。T48 で `HintModeCoordinator` の結線に置き換え、
/// `TemporaryHintModeStub` を削除する。
@MainActor
final class HintModeModule: AppModule {
    private let hotkey: HotkeyModule
    private let stub: TemporaryHintModeStub

    init(hotkey: HotkeyModule) {
        self.hotkey = hotkey
        stub = TemporaryHintModeStub(
            eventTap: hotkey.eventTap,
            tapEvents: hotkey.tapEvents,
            keyTranslator: hotkey.keyTranslator
        )
    }

    func start() {
        stub.start()
    }

    func stop() {
        stub.stop()
    }
}
