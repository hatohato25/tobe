#if DEBUG
    /// `--collect-once`: 1 回収集し、アプリ別のヒット数と診断をログに出す。
    ///
    /// T42 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct CollectOnceCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--collect-once", task: "T42")
        }
    }
#endif
