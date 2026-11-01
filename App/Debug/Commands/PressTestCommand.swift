#if DEBUG
    /// `--press-test`: Finder のツールバーのボタンを AXPress する。
    ///
    /// T46 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct PressTestCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--press-test", task: "T46")
        }
    }
#endif
