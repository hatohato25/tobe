#if DEBUG
    /// `--translate-test`: 押したキーと、変換された文字をログに出す。
    ///
    /// T35 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct TranslateTestCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--translate-test", task: "T35")
        }
    }
#endif
