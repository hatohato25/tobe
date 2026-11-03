#if DEBUG
    import AppKit
    import ApplicationServices
    import TobiCore

    /// `--walk-front-app`: 前面のアプリを `TreeWalker` + `AXTreeSource` で走査し、ヒット数・ロール別件数・所要時間を
    /// ログ（category: collector）に出す（T41）。
    ///
    /// - ターミナルから起動するとターミナルが前面になるため、起動してから `startDelay` 待ち、その時点の前面のアプリを
    ///   対象にする（その間に対象のアプリをクリックして前面にする）。
    /// - 根はそのアプリの `AXWindows` の各ウィンドウ（前面から）。クリップは画面の和集合（ウィンドウの frame での
    ///   狭め込みは `TreeWalker` が `AXWindow` で行う）。メニューバーは走査しない（T58 で収集に入る）。
    /// - 1 回目は相手のアプリが遅い（V-2・V-5）ため、`runCount` 回続けて走査し、回ごとに結果を出す。
    /// - ログに出すのはロール・件数・時間・エラーの種類・属性名だけ。要素のタイトルや値は読まない。
    struct WalkFrontAppCommand: DebugCommand {
        private static let startDelay: Duration = .seconds(3)
        private static let runCount = 2
        /// 走査の期限。取りこぼしの有無を確かめるため、本番の 150ms（design.md 8.5）より長くする。
        private nonisolated static let deadline: Duration = .seconds(1)

        func run() async throws {
            guard AXIsProcessTrusted() else { throw WalkFrontAppError.notTrusted }
            let client = AXClient()
            // 本番（T42）と同じく、参照ごとの設定をしていない参照を 50ms にする（AXTreeSource はこれを前提にする）
            try client.applySystemWideMessagingTimeout()

            Log.collector.notice("--walk-front-app: \(Self.startDelay, privacy: .public) 後の前面のアプリを走査する")
            try await Task.sleep(for: Self.startDelay)
            guard let app = NSWorkspace.shared.frontmostApplication else { throw WalkFrontAppError.noFrontmostApp }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                throw WalkFrontAppError.frontmostIsSelf
            }
            let pid = app.processIdentifier
            // アプリ名・bundle ID は手動確認で対象を見分けるため（画面の内容ではない）
            let appLabel = "\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"), pid \(pid))"
            Log.collector.notice("--walk-front-app: 対象 \(appLabel, privacy: .public)")

            let clip = try Self.screenUnion()
            let windows = try AXValueDecoder.elements(
                client.attributeValue(kAXWindowsAttribute, of: .application(pid: pid))
            )
            Log.collector.notice("--walk-front-app: AXWindows \(windows.count) 件")
            guard !windows.isEmpty else { throw WalkFrontAppError.noWindow }

            for run in 1...Self.runCount {
                let report = await Self.walkOffMain(client: client, windows: windows, clip: clip)
                report.log(run: run)
                if report.stoppedByAPIDisabled { throw WalkFrontAppError.apiDisabled }
            }
        }

        /// 画面の和集合（グローバル座標）。画面がなければ投げる。
        private static func screenUnion() throws(WalkFrontAppError) -> GlobalRect {
            let frames = ScreenGeometryProvider().currentScreens().map(\.frame.rect)
            guard let first = frames.first else { throw .noScreen }
            return GlobalRect(rect: frames.dropFirst().reduce(first) { $0.union($1) })
        }

        /// IPC はブロッキングするので、本番（design.md 8.5）と同じく GCD のキューで走査する。
        private static func walkOffMain(client: AXClient, windows: [AXElementRef], clip: GlobalRect) async -> WalkReport
        {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    continuation.resume(returning: walk(client: client, windows: windows, clip: clip))
                }
            }
        }

        /// 前面のウィンドウから順に走査する。ノード数の上限はアプリ単位なので、ウィンドウ間で分け合う（design.md 8.4）。
        private nonisolated static func walk(client: AXClient, windows: [AXElementRef], clip: GlobalRect) -> WalkReport
        {
            let clock = ContinuousClock()
            let issues = AXAttributeIssueCounter()
            let walker = TreeWalker(
                source: AXTreeSource(client: client, issues: issues),
                policy: TraversalPolicy(),
                now: { ContinuousClock.now }
            )
            let start = clock.now
            let deadlineInstant = start.advanced(by: Self.deadline)
            var results: [WalkResult<AXElementRef>] = []
            var visited = 0
            for window in windows {
                let result = walker.walk(
                    root: window,
                    clip: clip,
                    deadline: deadlineInstant,
                    nodeBudget: TreeWalkerLimits.nodeBudgetPerApp - visited,
                    isCancelled: { false }
                )
                results.append(result)
                visited += result.visitedNodeCount
                // 期限・上限・権限の取り消し・応答なしは、次のウィンドウでも同じになるので打ち切る（収集と同じ扱い）
                guard result.stopReason == .completed else { break }
            }
            return WalkReport(results: results, issues: issues.snapshot(), elapsed: start.duration(to: clock.now))
        }
    }

    /// 1 回の走査（全ウィンドウ）の結果。ログに出す値だけを持つ。
    private struct WalkReport: Sendable {
        let results: [WalkResult<AXElementRef>]
        let issues: [AXAttributeIssue: Int]
        let elapsed: Duration

        var stoppedByAPIDisabled: Bool {
            results.contains { $0.stopReason == .apiDisabled }
        }

        func log(run: Int) {
            let logger = Log.collector
            let hits = results.flatMap(\.hits)
            let visited = results.reduce(0) { $0 + $1.visitedNodeCount }
            logger.notice(
                """
                --walk-front-app [\(run)]: \(elapsed, privacy: .public)、ヒット \(hits.count) 件、\
                ノード \(visited) 件、走査したウィンドウ \(results.count) 件
                """
            )
            for (index, result) in results.enumerated() {
                let reason = String(describing: result.stopReason)
                logger.notice(
                    """
                      window[\(index)]: ヒット \(result.hits.count) 件、ノード \(result.visitedNodeCount) 件、\
                    終了 \(reason, privacy: .public)
                    """
                )
            }

            let roleCounts = Dictionary(grouping: hits, by: \.role).mapValues(\.count)
            for (role, count) in roleCounts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
                // ロールは AX の固定の語彙なので public で出す
                logger.notice("  role \(role, privacy: .public): \(count)")
            }

            var readErrors: [AccessibilityReadError: Int] = [:]
            for result in results {
                readErrors.merge(result.readErrors, uniquingKeysWith: +)
            }
            for (error, count) in readErrors.sorted(by: { $0.value > $1.value }) {
                logger.notice("  readError \(String(describing: error), privacy: .public): \(count)")
            }
            for (issue, count) in issues.sorted(by: { $0.value > $1.value }) {
                // 属性名と型の情報だけで、要素の値は含まない
                logger.notice("  attributeIssue \(issue.description, privacy: .public): \(count)")
            }
        }
    }

    private enum WalkFrontAppError: Error, CustomStringConvertible {
        case notTrusted
        case noFrontmostApp
        case frontmostIsSelf
        case noScreen
        case noWindow
        case apiDisabled

        var description: String {
            switch self {
            case .notTrusted:
                "アクセシビリティが許可されていない（システム設定 > プライバシーとセキュリティ > アクセシビリティ）"
            case .noFrontmostApp:
                "前面のアプリがない"
            case .frontmostIsSelf:
                "前面のアプリが Tobi 自身（対象のアプリを前面にしてから待つ）"
            case .noScreen:
                "画面がない"
            case .noWindow:
                "前面のアプリにウィンドウがない（ウィンドウを開いてから実行する）"
            case .apiDisabled:
                "走査中にアクセシビリティの権限が取り消された"
            }
        }
    }
#endif
