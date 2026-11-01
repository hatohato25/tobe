#if DEBUG
    /// `--click-test`: TextEdit の本文の中心をマウスイベントでクリックする。
    ///
    /// T47 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct ClickTestCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--click-test", task: "T47")
        }
    }
#endif
