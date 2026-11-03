#if DEBUG
    /// `--show-permission-guide`: 権限の案内画面を開く（T32）。
    ///
    /// - 今の `AXIsProcessTrusted()` の結果で「未許可」か「許可済み」を表示し、`PermissionMonitor` の通知で
    ///   表示を切り替える（許可しても閉じない。表示の切り替わりを目で確かめるため）。
    /// - 案内画面を閉じると、終了コード 0 で終える。
    /// - 「タップを作れなかった」の表示は、この引数では出さない（T33・T37 が切り替える。見た目は
    ///   `PermissionGuideView.swift` の Preview で確かめられる）。
    struct ShowPermissionGuideCommand: DebugCommand {
        func run() async throws {
            let monitor = PermissionMonitor()
            let guide = PermissionGuideWindowController()
            let changes = monitor.statusChanges()
            monitor.start()
            guide.show(state: Self.guideState(for: monitor.status))

            let following = Task { @MainActor in
                for await status in changes {
                    guide.state = Self.guideState(for: status)
                }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guide.onClose = {
                    // continuation は 1 回しか再開できないので、外してから再開する
                    guide.onClose = nil
                    continuation.resume()
                }
            }
            following.cancel()
            monitor.stop()
        }

        private static func guideState(for status: PermissionStatus) -> PermissionGuideState {
            switch status {
            case .granted: .granted
            case .notGranted: .notGranted
            }
        }
    }
#endif
