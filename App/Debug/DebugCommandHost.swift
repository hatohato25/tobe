#if DEBUG
    import AppKit
    import os

    /// Debug コマンドを 1 つ実行して終了する `NSApplicationDelegate`（`AppDelegate` の代わりに使う）。
    ///
    /// オーバーレイなど AppKit を使うコマンドがあるため、`NSApplication` を動かしたうえで実行する。
    /// 通常のモジュール（イベントタップなど）は起動しない。
    @MainActor
    final class DebugCommandHost: NSObject, NSApplicationDelegate {
        private let logger = Logger(subsystem: "io.github.hatohato25.tobe", category: "debug")
        private let argument: String
        private let commandType: any DebugCommand.Type

        init(argument: String, commandType: any DebugCommand.Type) {
            self.argument = argument
            self.commandType = commandType
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            // Info.plist の LSUIElement と同じく、Dock と ⌘Tab に出さない。
            NSApp.setActivationPolicy(.accessory)

            let command = commandType.init()
            let argument = argument
            let logger = logger
            logger.info("Debug コマンドを開始します: \(argument, privacy: .public)")
            Task { @MainActor in
                do {
                    try await command.run()
                    logger.info("Debug コマンドが完了しました: \(argument, privacy: .public)")
                    exit(EXIT_SUCCESS)
                } catch {
                    logger.error(
                        """
                        Debug コマンドが失敗しました: \(argument, privacy: .public): \
                        \(String(describing: error), privacy: .public)
                        """
                    )
                    // 失敗を終了コードで区別できるよう、NSApp.terminate(_:)（終了コード 0）ではなく exit で終える。
                    exit(EXIT_FAILURE)
                }
            }
        }
    }
#endif
