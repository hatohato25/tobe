#if DEBUG
    /// `--dump-screens`: 画面ごとの座標の情報をログに出す。
    ///
    /// T43 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct DumpScreensCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--dump-screens", task: "T43")
        }
    }
#endif
