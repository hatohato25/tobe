#if DEBUG
    /// `--ax-selftest`: Finder の最前面ウィンドウの属性を型付きの値として読み、ログに出す。
    ///
    /// T40 が実装する。それまでは未実装を示すエラーを投げる（`DebugCommandHost` がログに出し、終了コード 1 で終える）。
    struct AXSelfTestCommand: DebugCommand {
        func run() async throws {
            throw DebugCommandError.notImplemented(argument: "--ax-selftest", task: "T40")
        }
    }
#endif
