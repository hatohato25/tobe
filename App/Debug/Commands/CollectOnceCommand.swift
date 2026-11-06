#if DEBUG
    import AppKit
    import TobeCore

    /// `--collect-once`: `AXElementCollector` で 1 回収集し、アプリごとのヒット数・時間・診断をログ（category:
    /// collector）に出す（T42）。
    ///
    /// - 期限は本番と同じ 150ms（design.md 8.5）。打ち切りや応答なしが本番と同じ条件で診断に出るようにする。
    /// - 全体の時間が「期限 + 50ms」（実行中の IPC 1 回分。N-1.3）を超えたら警告を出す。
    /// - 収集した要素がすべて `ElementHandleRegistry.lookup` で引けることも確かめる（T46 の操作が使う口）。
    /// - ログに出すのは PID・アプリ名・件数・時間・ロール・診断だけ。要素のタイトルや値は読まない。
    struct CollectOnceCommand: DebugCommand {
        /// 本番の期限（design.md 8.5。Coordinator が判定時刻 + 150ms を渡す）。
        private static let deadline: Duration = .milliseconds(150)
        /// 期限を過ぎてからも待ちうる、実行中の IPC 1 回分（design.md 8.5「最悪の場合」）。
        private static let ipcAllowance: Duration = .milliseconds(50)

        func run() async throws {
            let logger = Log.collector
            let registry = ElementHandleRegistry()
            let collector = AXElementCollector(registry: registry, contentEnabler: ContentAccessibilityEnabler())
            let start = ContinuousClock.now
            let outcome = try await collector.collectWithReport(deadline: start.advanced(by: Self.deadline))
            let elapsed = start.duration(to: .now)

            for line in outcome.report.logLines() {
                logger.notice("--collect-once: \(line, privacy: .public)")
            }
            for app in outcome.report.apps {
                // アプリ名は手動確認で PID を見分けるため（画面の内容ではない）
                let name = NSRunningApplication(processIdentifier: app.pid.rawValue)?.localizedName ?? "（終了済み）"
                logger.notice("--collect-once: pid \(app.pid.rawValue) = \(name, privacy: .public)")
            }

            let result = outcome.result
            for diagnostic in result.diagnostics {
                logger.notice("--collect-once: 診断 \(String(describing: diagnostic), privacy: .public)")
            }
            let roleCounts = Dictionary(grouping: result.elements, by: \.role).mapValues(\.count)
            for (role, count) in roleCounts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
                // ロールは AX の固定の語彙なので public で出す
                logger.notice("--collect-once: role \(role, privacy: .public): \(count)")
            }

            let resolvable = result.elements.filter { registry.lookup($0.id) != nil }.count
            logger.notice(
                """
                --collect-once: 全体 \(elapsed, privacy: .public)、要素 \(result.elements.count) 件\
                （lookup で引けた \(resolvable) 件）、遮蔽の判定用ウィンドウ \(result.windows.count) 件
                """
            )
            if elapsed > Self.deadline + Self.ipcAllowance {
                logger.warning(
                    "--collect-once: 全体が期限 + 50ms（\(Self.deadline + Self.ipcAllowance, privacy: .public)）を超えた")
            }
        }
    }
#endif
