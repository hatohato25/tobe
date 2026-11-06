#if DEBUG
    import AppKit
    import TobeCore
    import os

    /// `--translate-test`: 押したキーの keyCode・`KeyTranslator` が変換した文字・`HintKeyInput.classify` の結果をログに出す。
    ///
    /// イベントタップは使わず、小さなウィンドウを 1 つ出して `NSEvent` のローカルモニタでキーを受ける
    /// （アクセシビリティ権限なしで確かめられるようにするため）。修飾キーとリピートの有無は、本番のタップと同じ値になるよう
    /// `NSEvent.cgEvent` から読む。
    /// ウィンドウを閉じると終了する（終了コード 0）。
    ///
    /// Debug 専用のコマンドなので、押したキーと文字をそのままログに出す（確認がこのコマンドの目的のため）。
    struct TranslateTestCommand: DebugCommand {
        func run() async throws {
            let session = TranslateTestSession()
            await session.runUntilWindowCloses()
        }
    }

    @MainActor
    private final class TranslateTestSession {
        private let logger = Logger(subsystem: "io.github.hatohato25.tobe", category: "debug")
        private let translator = KeyTranslator()
        private let window: NSWindow

        init() {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Tobe --translate-test"
            // 閉じたときに解放させず、このセッションが所有する（NSWindow の既定は閉じると解放）。
            window.isReleasedWhenClosed = false
            let label = NSTextField(
                labelWithString: "このウィンドウを前面にしてキーを押す。結果はログ（category: debug）に出る。閉じると終了。"
            )
            label.frame = NSRect(x: 16, y: 40, width: 388, height: 40)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            window.contentView?.addSubview(label)
        }

        func runUntilWindowCloses() async {
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // ローカルモニタのハンドラはメインスレッドで呼ばれる。
                MainActor.assumeIsolated {
                    self?.log(event)
                }
                // キーを他へ渡さない（ファーストレスポンダがないためビープが鳴るのを防ぐ）。
                return nil
            }
            defer {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
            if monitor == nil {
                logger.error("NSEvent のローカルモニタを登録できませんでした")
                return
            }

            logger.info(
                "--translate-test: レイアウト \(self.translator.currentLayoutID ?? "（読み込み失敗）", privacy: .public)"
            )
            window.center()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)

            let closes = NotificationCenter.default.notifications(
                named: NSWindow.willCloseNotification,
                object: window
            )
            for await _ in closes.map({ _ in () }) {
                break
            }
        }

        private func log(_ event: NSEvent) {
            guard let cgEvent = event.cgEvent else {
                logger.error("NSEvent から CGEvent を取得できませんでした（keyCode \(event.keyCode, privacy: .public)）")
                return
            }
            let keyCode = event.keyCode
            let flags = ModifierFlags(rawValue: cgEvent.flags.rawValue)
            let isRepeat = cgEvent.getIntegerValueField(.keyboardEventAutorepeat) != 0

            let translatedDescription: String
            do {
                if let character = try translator.character(forKeyCode: keyCode) {
                    translatedDescription = "\"\(character)\""
                } else {
                    translatedDescription = "nil"
                }
            } catch {
                translatedDescription = "エラー: \(error.description)"
            }
            let input = translator.hintKeyInput(keyCode: keyCode, flags: flags, isRepeat: isRepeat)

            logger.info(
                """
                keyCode=0x\(String(keyCode, radix: 16), privacy: .public) \
                translated=\(translatedDescription, privacy: .public) \
                flags=0x\(String(flags.rawValue, radix: 16), privacy: .public) \
                repeat=\(isRepeat, privacy: .public) \
                classify=\(String(describing: input), privacy: .public) \
                layout=\(self.translator.currentLayoutID ?? "（読み込み失敗）", privacy: .public)
                """
            )
        }
    }
#endif
