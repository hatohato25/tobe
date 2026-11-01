#if DEBUG
    /// `--dump-windows`: 収集対象のウィンドウの一覧を、前面から順にログに出す。
    ///
    /// T39 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct DumpWindowsCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--dump-windows", task: "T39")
        }
    }
#endif
