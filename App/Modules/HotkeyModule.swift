/// 起動キーの検出（CGEventTap）を担当するモジュール。
///
/// T3 の時点では空の実装。イベントタップと、他のモジュールへ渡す値（`eventTap`、`tapEvents` など）は
/// T37 がこのファイルに足す。
@MainActor
final class HotkeyModule: AppModule {
    init() {}

    func start() throws {}

    func stop() {}
}
