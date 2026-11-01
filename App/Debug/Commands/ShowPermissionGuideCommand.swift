#if DEBUG
    /// `--show-permission-guide`: 権限の案内画面を開く。
    ///
    /// T32 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct ShowPermissionGuideCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--show-permission-guide", task: "T32")
        }
    }
#endif
