#if DEBUG
    /// `--overlay-demo`: 固定のラベルを全ディスプレイに表示する。
    ///
    /// T44 / T45 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct OverlayDemoCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--overlay-demo", task: "T44 / T45")
        }
    }
#endif
