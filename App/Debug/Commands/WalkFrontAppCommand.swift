#if DEBUG
    /// `--walk-front-app`: 前面アプリを走査し、ヒット数・ロール別件数・所要時間をログに出す。
    ///
    /// T41 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct WalkFrontAppCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--walk-front-app", task: "T41")
        }
    }
#endif
