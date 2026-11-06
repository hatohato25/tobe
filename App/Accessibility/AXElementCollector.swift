// swiftlint:disable file_length
// 収集の段階（計画・アプリ 1 つの走査・内訳）を private の型でこのファイルに閉じ込めているため 400 行を超える。
// 別のファイルに分けると、これらの型を internal に開く必要がある（T42 の担当ファイルの制約もある）。

import AppKit
import ApplicationServices
import CoreGraphics
import Dispatch
import Synchronization
import TobeCore
import os

/// `ElementCollecting` の AX 実装。画面に見えているウィンドウを列挙し、アプリ単位で並列に AX ツリーを走査する
/// （design.md 8.1、8.4、8.5、8.7、13 章、D-9、D-12、D-29）。
///
/// 1 回の収集の流れ:
/// 1. 権限を確かめる（`AXIsProcessTrusted()`。未許可なら `CollectionError.accessibilityNotTrusted`）。
/// 2. `ElementHandleRegistry.beginCollection()` で前の収集の対応を消す。
/// 3. システム全体の IPC のタイムアウトを 50ms にする（`AXClient.applySystemWideMessagingTimeout()`。下の「タイムアウト」）。
/// 4. `WindowEnumerator` でウィンドウを列挙し、前面の 1 枚に完全に覆われたウィンドウと、画面の外にあるウィンドウを除く。
///    前面のアプリ（`NSWorkspace.frontmostApplication`。Tobe 自身なら無し）には、メニューバーと開いているメニューの
///    ウィンドウも割り当てる（design.md 8.1 手順 2、D-31。下の「メニュー」）。
/// 5. 所有者の PID ごとにまとめ、アプリごとに GCD のキュー（`.userInteractive`）で `AppCollectionJob` を実行し、
///    `withTaskGroup` で全部を待つ（同じアプリの中は前面のウィンドウから順に直列。D-12）。
/// 6. 集まったヒットを `ElementHandleRegistry` に登録して `ElementID` を振り、`CollectionResult` にする。
///
/// タイムアウト: 3 のシステム全体の設定は、起動時に 1 回ではなく**収集ごとに**呼ぶ。プロセス内の値の書き換えで IPC は
/// なく、毎回でも費用はほぼない。起動時だけにすると、権限の許可前に起動した場合（再起動なしで使える。Q-25）に設定が
/// 効いているかを確かめられない（未許可での成否は未検証）。また、走査の参照はアプリの要素から収集ごとに取り直すので、
/// 前の収集で参照に設定した短いタイムアウトは残らない（T41 の前提）。
///
/// キャンセル: 呼び出し元の Task がキャンセルされたら、`withTaskCancellationHandler` でフラグ（`Mutex<Bool>`）を立てる。
/// 各アプリの走査は IPC の前ごとにフラグを確かめて止まり（実行中の IPC 1 回分、最大 50ms は待つ）、すべて止まってから
/// `CollectionError.cancelled` を投げる。
///
/// メニュー（F-2.14〜F-2.16、design.md 8.1 手順 2、8.6、D-31）: 前面のアプリだけ、次を別の根として走査する。
/// - メニューバー: アプリの `AXMenuBar`。項目（`AXMenuBarItem`）はリーフなので、閉じたメニューの中は辿らない（T64）。
///   根の要素は、frame が一致するメニューバーのウィンドウ（WindowServer が所有する）に属させる。
/// - 開いているメニュー: 前面のアプリが所有する `kCGPopUpMenuWindowLevel` のウィンドウごとに、その中心を AX でヒット
///   テストし、親を辿って `AXMenu` を探す。frame が 1pt 以内で一致すれば、そのウィンドウの `WindowID` の根にする。
///   メニューバーのウィンドウに属させると、自分のメニューに遮蔽されて消えるため。
/// - Dock、メニューバー右側（ステータスアイテム、コントロールセンター）、通知は、前面のアプリのものではないので走査しない。
///
/// シート（保存シートなど）: AX では親ウィンドウの子（`AXSheet`）で `AXWindows` に入らないが、CG では親より前面の別の
/// ウィンドウになる。親の `WindowID` に属させると、自分のシートに遮蔽されて消える（8.6）。そこで、対応する AX
/// ウィンドウがない CG のウィンドウが残ったときだけ、照合した AX ウィンドウの子からシートを探し、frame が 1pt 以内で
/// 一致すれば、その CG のウィンドウの `WindowID` の根にする（D-9・D-31 と同じ考え方）。
/// 相手のアプリの AX を有効にする属性（Chromium・Electron 向けのもの）は書き込まない（F-2.7）。
///
/// スレッド: 状態は `registry`（ロック付き）だけなので、どの隔離から呼んでもよい。IPC はすべて GCD のキューで行い、
/// 呼び出し元（MainActor の Coordinator）や Swift Concurrency の協調スレッドプールをブロックしない。
struct AXElementCollector: ElementCollecting {
    private let client = AXClient()
    private let windowEnumerator = WindowEnumerator()
    private let policy = TraversalPolicy()
    private let contentEnabler: ContentAccessibilityEnabler
    private let registry: ElementHandleRegistry

    /// - Parameters:
    ///   - registry: 収集した要素の対応表。同じものを `AXActionPerformer` に `registry.lookup` で渡す（T48）。
    ///   - contentEnabler: 見えているウィンドウのアプリに、収集のときに中身の公開を頼む。
    init(registry: ElementHandleRegistry, contentEnabler: ContentAccessibilityEnabler) {
        self.contentEnabler = contentEnabler
        self.registry = registry
    }

    func collect(deadline: ContinuousClock.Instant) async throws(CollectionError) -> CollectionResult {
        let outcome = try await collectWithReport(deadline: deadline)
        outcome.report.logLines().forEach { line in
            // 行は PID・件数・時間・終了理由・エラーの種類・属性名だけで作る（CollectionReport）
            Log.collector.info("\(line, privacy: .public)")
        }
        return outcome.result
    }

    /// `collect(deadline:)` と同じ収集をし、アプリごとの内訳（`CollectionReport`）も返す。ログには出さない。
    /// `collect(deadline:)` と Debug の `--collect-once` が使う。
    func collectWithReport(deadline: ContinuousClock.Instant) async throws(CollectionError) -> CollectionOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        guard AXIsProcessTrusted() else { throw .accessibilityNotTrusted }
        guard !Task.isCancelled else { throw .cancelled }
        let generation = registry.beginCollection()
        try applySystemWideTimeout()

        let frontPID = await Self.frontmostApplicationPID()
        let snapshot = try await Self.runOnQueue { [windowEnumerator] in
            Result { () throws(CollectionError) in try windowEnumerator.enumerate() }
        }.get()
        let plan = CollectionPlan(snapshot: snapshot, screenUnion: Self.activeDisplayUnion(), frontPID: frontPID)

        let flag = CancellationFlag()
        let apps = await withTaskCancellationHandler {
            await collectApps(plan.apps, deadline: deadline, flag: flag)
        } onCancel: {
            flag.cancel()
        }

        guard !flag.isCancelled, !Task.isCancelled else { throw .cancelled }
        guard !apps.contains(where: { $0.stopReason == .apiDisabled }) else { throw .accessibilityNotTrusted }

        let hits = apps.flatMap(\.hits)
        // 世代が古い = この収集の途中で次の収集が始まったか、セッションが終わった。結果は使われないので取り消し扱い
        guard let ids = registry.register(hits.map(\.element), for: generation) else { throw .cancelled }
        let elements = zip(ids, hits).map { id, hit in
            CollectedElement(id: id, windowID: hit.windowID, frame: hit.frame, role: hit.role)
        }
        let result = CollectionResult(
            windows: snapshot.occlusionWindows,
            elements: elements,
            diagnostics: snapshot.diagnostics + apps.flatMap(\.diagnostics)
        )
        Signposts.collected(elementCount: elements.count)

        let report = CollectionReport(
            elapsed: start.duration(to: clock.now),
            elementCount: elements.count,
            traversalTargetCount: snapshot.traversalTargets.count,
            coveredWindowCount: plan.coveredWindowCount,
            offscreenWindowCount: plan.offscreenWindowCount,
            hasScreens: plan.hasScreens,
            apps: apps.map(\.report)
        )
        return CollectionOutcome(result: result, report: report)
    }

    // MARK: - 内部

    /// アプリごとに GCD のキューで走査し、前面のアプリから順に並べて返す。
    private func collectApps(
        _ apps: [AppPlan],
        deadline: ContinuousClock.Instant,
        flag: CancellationFlag
    ) async -> [AppCollection] {
        await withTaskGroup(of: (Int, AppCollection).self) { group in
            for (index, app) in apps.enumerated() {
                let job = AppCollectionJob(
                    client: client, policy: policy, contentEnabler: contentEnabler, plan: app, deadline: deadline,
                    flag: flag
                )
                group.addTask {
                    (index, await Self.runOnQueue { job.run() })
                }
            }
            var collections: [(Int, AppCollection)] = []
            for await entry in group {
                collections.append(entry)
            }
            return collections.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// システム全体の IPC のタイムアウトを 50ms にする（D-29。型の説明の「タイムアウト」）。
    ///
    /// 権限の取り消し（`.apiDisabled`）は収集を続けられないので投げる。それ以外の失敗は収集を止めずにエラーとして
    /// ログに残す（安全網が効かないだけで、期限が近いときの参照ごとの設定は効く。黙って続けはしない）。
    private func applySystemWideTimeout() throws(CollectionError) {
        do throws(AccessibilityReadError) {
            try client.applySystemWideMessagingTimeout()
        } catch .apiDisabled {
            throw .accessibilityNotTrusted
        } catch {
            Log.collector.error(
                "システム全体のタイムアウトを設定できなかった: \(String(describing: error), privacy: .public)")
        }
    }

    /// ブロッキングする処理（IPC、`CGWindowListCopyWindowInfo`）を GCD のキューで実行する（design.md 8.5、D-12）。
    /// Swift Concurrency の協調スレッドプールのスレッドを、IPC の待ちで塞がないため。
    private static func runOnQueue<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// メニューバーと開いているメニューを走査する、前面のアプリ（design.md 8.1 手順 2）。
    ///
    /// `NSWorkspace` は MainActor で読む（AppKit の状態で、通知で更新される）。呼び出し元の Coordinator は MainActor
    /// なので、ここで待つのは MainActor への 1 回の切り替えだけ。前面が Tobe 自身（設定画面など）なら nil にする（F-2.12）。
    @MainActor
    private static func frontmostApplicationPID() -> ProcessID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return ProcessID(rawValue: app.processIdentifier)
    }

    /// 有効なディスプレイ全体の和集合（グローバル座標）。ディスプレイがない・取れないときは nil。
    ///
    /// `CGDisplayBounds` は AX・`CGWindowList` と同じ左上原点のグローバル座標なので、変換は要らない
    /// （AppKit の座標からの変換は `ScreenGeometryProvider` の 1 か所だけ。これは変換ではない）。
    /// `NSScreen` は MainActor でしか読めないため、MainActor の外で動く収集では CoreGraphics から読む。
    private static func activeDisplayUnion() -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        let bounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
        guard let first = bounds.first else { return nil }
        return bounds.dropFirst().reduce(first) { $0.union($1) }
    }
}

/// `AXElementCollector.collectWithReport(deadline:)` の結果。
struct CollectionOutcome: Sendable {
    let result: CollectionResult
    let report: CollectionReport
}

// MARK: - 収集の計画

/// 列挙したウィンドウから、走査するアプリとウィンドウ（根のクリップ付き）を決める（design.md 8.1 手順 3〜4）。
private struct CollectionPlan {
    /// 前面のアプリ（最前面のウィンドウの zIndex が小さいアプリ）から順。
    let apps: [AppPlan]
    let coveredWindowCount: Int
    let offscreenWindowCount: Int
    let hasScreens: Bool

    /// - Parameter frontPID: 前面のアプリ。メニューバーと開いているメニューを、このアプリの根に加える（nil なら加えない）。
    init(snapshot: WindowListSnapshot, screenUnion: CGRect?, frontPID: ProcessID?) {
        hasScreens = screenUnion != nil
        if screenUnion == nil {
            // 画面が 0 枚なら見える範囲がないので何も走査しない（ヒントモードは要素 0 件として扱う）
            Log.collector.warning("有効なディスプレイが取れないため、ウィンドウを走査しない")
        }
        var covered = 0
        var offscreen = 0
        var groups: [AppPlan] = []
        var groupIndexByPID: [ProcessID: Int] = [:]
        for window in snapshot.traversalTargets {
            guard !OcclusionFilter.isFullyCovered(window, by: snapshot.occlusionWindows) else {
                covered += 1
                continue
            }
            guard let target = WindowTarget(window: window, screenUnion: screenUnion) else {
                offscreen += 1
                continue
            }
            if let index = groupIndexByPID[window.ownerPID] {
                groups[index].targets.append(target)
            } else {
                groupIndexByPID[window.ownerPID] = groups.count
                groups.append(AppPlan(pid: window.ownerPID, targets: [target], menus: nil))
            }
        }
        if let frontPID, let menus = MenuTargets(snapshot: snapshot, frontPID: frontPID, screenUnion: screenUnion) {
            if let index = groupIndexByPID[frontPID] {
                groups[index].menus = menus
            } else {
                // 通常のウィンドウがない前面のアプリ（ウィンドウを閉じた Finder など）も、メニューバーは走査する。
                // メニューは最前面にあるので、アプリの並びの先頭に置く
                groups.insert(AppPlan(pid: frontPID, targets: [], menus: menus), at: 0)
            }
        }
        // traversalTargets は前面から順なので、アプリの順も各アプリの中のウィンドウの順も前面から
        apps = groups
        coveredWindowCount = covered
        offscreenWindowCount = offscreen
    }
}

/// 1 つのアプリで走査するウィンドウ（前面から順）。
private struct AppPlan: Sendable {
    let pid: ProcessID
    /// レイヤー 0 のウィンドウ。
    var targets: [WindowTarget]
    /// 前面のアプリだけが持つ、メニューバーと開いているメニューのウィンドウ。
    var menus: MenuTargets?
}

/// 走査する CG のウィンドウと、その根のクリップ。
private struct WindowTarget: Sendable {
    let window: WindowInfo
    let clip: GlobalRect

    /// 根のクリップは、ウィンドウの frame と画面の和集合の積（design.md 8.4）。画面がない・画面の外なら nil。
    init?(window: WindowInfo, screenUnion: CGRect?) {
        let clip = screenUnion.map { window.frame.rect.intersection($0) } ?? .null
        guard !clip.isEmpty else { return nil }
        self.window = window
        self.clip = GlobalRect(rect: clip)
    }
}

/// 前面のアプリの根の候補にする、メニューのウィンドウ（design.md 8.1 手順 2、D-31）。
private struct MenuTargets: Sendable {
    /// メニューバーのウィンドウ（ディスプレイごと）。`AXMenuBar` と frame が一致したものを根の `WindowID` にする。
    let menuBarWindows: [WindowTarget]
    /// 前面のアプリが所有する、開いているメニューのウィンドウ（前面から順）。
    let popUpMenuWindows: [WindowTarget]

    /// 画面に見えているメニューのウィンドウが 1 枚もなければ nil（メニューバーを自動的に隠している場合など）。
    init?(snapshot: WindowListSnapshot, frontPID: ProcessID, screenUnion: CGRect?) {
        menuBarWindows = snapshot.menuBarWindows.compactMap { WindowTarget(window: $0, screenUnion: screenUnion) }
        popUpMenuWindows = snapshot.popUpMenuWindows(ownedBy: frontPID).compactMap {
            WindowTarget(window: $0, screenUnion: screenUnion)
        }
        guard !menuBarWindows.isEmpty || !popUpMenuWindows.isEmpty else { return nil }
    }
}

/// 呼び出し元の Task のキャンセルを、GCD のキューで動く走査に伝えるフラグ（design.md 8.5、13 章、T16 の注記）。
private final class CancellationFlag: Sendable {
    private let value = Mutex(false)

    var isCancelled: Bool {
        value.withLock { $0 }
    }

    func cancel() {
        value.withLock { $0 = true }
    }
}

// MARK: - アプリ 1 つの走査

/// 1 つのアプリの走査（design.md 8.1 手順 4〜5、8.4、8.7）。GCD のキューの上で同期に実行する。
///
/// 0. 前面のアプリなら、開いているメニューとメニューバーの根を決める（`resolveMenuRoots`。型の説明の「メニュー」）。
/// 1. アプリの要素（収集ごとに作り直す）の `AXWindows` を読む。
/// 2. 各 AX ウィンドウの `AXPosition` / `AXSize` / `AXMinimized` を 1 回の IPC で読み、最小化されておらず、frame が
///    CG のウィンドウの bounds と 1pt 以内で一致するものを、その `WindowID` の根にする（D-9）。一致しない AX
///    ウィンドウ（別の Space、画面外など）は捨てる。CG のウィンドウがすべて対応付いたら、残りの AX ウィンドウは読まない。
///    対応付かない CG のウィンドウが残ったら、照合した AX ウィンドウのシートと照合する（`resolveSheetRoots`）。
/// 3. 根を前面から順（開いているメニュー、メニューバー、ウィンドウとシート）に `TreeWalker` で走査する。ノード数の上限は
///    アプリ単位なので、次の根には「4000 − それまでの `visitedNodeCount` の合計」を渡す（design.md 8.4、T23）。
///    終了理由が `completed` 以外（期限、上限、応答なし、キャンセル、権限の取り消し）なら、残りの根は走査しない。
///
/// 1〜2 の IPC も `TreeWalker` と同じ規則で扱う: IPC の前に期限とキャンセルを確かめ、期限までの残りが 50ms より短ければ
/// その参照に残りを設定する。エラーは design.md 8.7 の表のとおり（`cannotComplete` が 2 回続いたら応答なし）。
/// ただし `AXWindows` の `cannotComplete` は 1 回で応答なしとする（アプリの根が読めないと、ほかに読むものがない）。
private struct AppCollectionJob: Sendable {
    /// AX のウィンドウと CG のウィンドウを同じものとみなす、位置と大きさの差の上限（D-9）。
    static let frameMatchTolerance: CGFloat = 1
    /// AX ウィンドウの frame の照合で、1 回の IPC で読む属性。
    static let windowAttributes: [String] = [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute]

    let client: AXClient
    let policy: TraversalPolicy
    let contentEnabler: ContentAccessibilityEnabler
    let plan: AppPlan
    let deadline: ContinuousClock.Instant
    let flag: CancellationFlag

    func run() -> AppCollection {
        let clock = ContinuousClock()
        let start = clock.now
        let issues = AXAttributeIssueCounter()
        var state = JobState()
        var stopReason = WalkStopReason.completed
        contentEnabler.enableIfNeeded(for: plan.pid)
        var roots: [WalkRoot] = []
        do throws(JobInterruption) {
            roots = try resolveMenuRoots(state: &state, issues: issues)
            roots += try resolveWindowRoots(state: &state, issues: issues)
        } catch {
            stopReason = error.reason
        }

        let walked = walk(roots, state: &state, issues: issues)
        if let reason = walked.stopReason {
            stopReason = reason
        }
        let hits = walked.hits
        let visited = walked.visitedNodeCount

        let report = AppCollectionReport(
            pid: plan.pid,
            hitCount: hits.count,
            visitedNodeCount: visited,
            targetWindowCount: plan.targets.count,
            rootCount: state.windowRootCount,
            menus: state.menuReport,
            sheets: state.sheetReport,
            stopReason: stopReason,
            readErrors: state.readErrors,
            issues: issues.snapshot(),
            elapsed: start.duration(to: clock.now)
        )
        return AppCollection(hits: hits, report: report)
    }

    /// `walk(_:state:issues:)` の結果。
    private struct WalkOutcome {
        var hits: [AppHit] = []
        var visitedNodeCount = 0
        /// `completed` 以外で止まった根があれば、その終了理由（残りの根は走査していない）。
        var stopReason: WalkStopReason?
    }

    /// 根を前面から順に `TreeWalker` で走査する。ノード数の上限はアプリ単位で、根ごとに残りを渡す（型の説明の 3）。
    private func walk(_ roots: [WalkRoot], state: inout JobState, issues: AXAttributeIssueCounter) -> WalkOutcome {
        var outcome = WalkOutcome()
        let walker = TreeWalker(
            source: AXTreeSource(client: client, issues: issues),
            policy: policy,
            now: { ContinuousClock.now }
        )
        for root in roots {
            let result = walker.walk(
                root: root.element,
                clip: root.clip,
                deadline: deadline,
                nodeBudget: TreeWalkerLimits.nodeBudgetPerApp - outcome.visitedNodeCount,
                isCancelled: { flag.isCancelled }
            )
            outcome.visitedNodeCount += result.visitedNodeCount
            state.readErrors.merge(result.readErrors, uniquingKeysWith: +)
            outcome.hits += result.hits.map { hit in
                AppHit(element: hit.node, windowID: root.windowID, frame: hit.frame, role: hit.role)
            }
            guard result.stopReason == .completed else {
                outcome.stopReason = result.stopReason
                break
            }
        }
        return outcome
    }

    // MARK: 根を決める

    /// `AXWindows` を読み、CG のウィンドウと frame で対応付けた根を、CG のウィンドウの順（前面から）で返す。
    private func resolveWindowRoots(
        state: inout JobState,
        issues: AXAttributeIssueCounter
    ) throws(JobInterruption) -> [WalkRoot] {
        // メニューだけを走査する前面のアプリ（通常のウィンドウがない）では、AXWindows を読む IPC を省く
        guard !plan.targets.isEmpty else { return [] }
        let app = makeApplicationElement()
        try checkBeforeIPC()
        let windowsValue: CFTypeRef
        do throws(AccessibilityReadError) {
            try setTimeoutIfNeeded(on: app)
            windowsValue = try client.attributeValue(kAXWindowsAttribute, of: app)
        } catch .attributeUnsupported {
            // ウィンドウの属性を持たないアプリ。走査するものがないだけで、失敗ではない
            return []
        } catch {
            try state.fail(error)
            if error == .cannotComplete { throw JobInterruption(reason: .unresponsive) }
            return []
        }
        state.succeeded()
        let axWindows: [AXElementRef]
        do throws(AXValueDecodingError) {
            axWindows = try AXValueDecoder.elements(windowsValue)
        } catch {
            if case .typeMismatch(let expected, let actualTypeID) = error {
                issues.record(
                    .typeMismatch(attribute: kAXWindowsAttribute, expected: expected, actualTypeID: actualTypeID))
            }
            return []
        }

        var matched = [WalkRoot?](repeating: nil, count: plan.targets.count)
        for axWindow in axWindows where matched.contains(where: { $0 == nil }) {
            guard let frame = try readWindowFrame(axWindow, state: &state, issues: issues) else { continue }
            let index = plan.targets.indices.first { index in
                matched[index] == nil && Self.framesMatch(frame, plan.targets[index].window.frame.rect)
            }
            guard let index else { continue }
            let target = plan.targets[index]
            matched[index] = WalkRoot(element: axWindow, windowID: target.window.id, clip: target.clip)
        }
        try resolveSheetRoots(&matched, state: &state, issues: issues)
        // matched は plan.targets の順（前面から）なので、シートはその親ウィンドウより先に走査する
        let roots = matched.compactMap(\.self)
        state.windowRootCount = roots.count
        return roots
    }

    /// アプリの要素。根を決める段階ごとに作るので、前の収集で設定した短いタイムアウトが残らない（T41 の前提）。
    private func makeApplicationElement() -> AXElementRef {
        AXElementRef.application(pid: plan.pid.rawValue)
    }

    /// AX ウィンドウ（と `AXMenuBar`）の frame（左上原点のグローバル座標）。最小化されている、読めない、位置か大きさが
    /// ないときは nil。最小化の属性を持たない要素（`AXMenuBar`）は、最小化されていないものとして扱う。
    private func readWindowFrame(
        _ window: AXElementRef,
        state: inout JobState,
        issues: AXAttributeIssueCounter
    ) throws(JobInterruption) -> CGRect? {
        try checkBeforeIPC()
        do throws(AccessibilityReadError) {
            try setTimeoutIfNeeded(on: window)
            let values = try client.attributeValues(Self.windowAttributes, of: window)
            state.succeeded()
            let position = try Self.slot(kAXPositionAttribute, issues: issues) { () throws(AXValueDecodingError) in
                try values.point(kAXPositionAttribute)
            }
            let size = try Self.slot(kAXSizeAttribute, issues: issues) { () throws(AXValueDecodingError) in
                try values.size(kAXSizeAttribute)
            }
            // 最小化の属性がないウィンドウは最小化できないものとして扱う（最小化したウィンドウは CG の一覧に
            // 入らないので、frame の照合だけでも対応付かない。これは二重の確認）
            let isMinimized = try Self.slot(kAXMinimizedAttribute, issues: issues) { () throws(AXValueDecodingError) in
                try values.bool(kAXMinimizedAttribute)
            }
            guard let position, let size, isMinimized != true else { return nil }
            return CGRect(origin: position, size: size)
        } catch {
            try state.fail(error)
            return nil
        }
    }

    // MARK: 共通

    /// IPC を始める前に、キャンセルと期限を確かめる（`TreeWalker` と同じ。期限を過ぎたら新しい IPC を始めない）。
    private func checkBeforeIPC() throws(JobInterruption) {
        if flag.isCancelled { throw JobInterruption(reason: .cancelled) }
        if ContinuousClock.now >= deadline { throw JobInterruption(reason: .deadline) }
    }

    /// 期限までの残りが 50ms より短いときだけ、その参照に残りを設定する（D-29。`AXTreeSource` と同じ規則）。
    private func setTimeoutIfNeeded(on element: AXElementRef) throws(AccessibilityReadError) {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining < AXClient.systemWideMessagingTimeout else { return }
        try client.setMessagingTimeout(remaining, for: element)
    }

    /// 一括取得の 1 項目を取り出す。「属性なし」として扱うものは nil にし、要素自体の失敗だけを投げる
    /// （`AXTreeSource` と同じ扱い。design.md 8.3、8.7）。
    private static func slot<Value>(
        _ attribute: String,
        issues: AXAttributeIssueCounter,
        _ decode: () throws(AXValueDecodingError) -> Value
    ) throws(AccessibilityReadError) -> Value? {
        do {
            return try decode()
        } catch {
            switch error {
            case .typeMismatch(let expected, let actualTypeID):
                issues.record(.typeMismatch(attribute: attribute, expected: expected, actualTypeID: actualTypeID))
            case .attributeError(let readError):
                switch readError {
                case .attributeUnsupported:
                    break
                case .invalidElement, .cannotComplete, .apiDisabled:
                    throw readError
                case .actionUnsupported, .notImplemented, .other:
                    issues.record(.attributeError(attribute: attribute, readError))
                }
            case .notRequested(let name):
                // windowAttributes にない属性を取り出したときだけ起きる。このファイルの書き誤りなので、黙って属性なしにしない
                preconditionFailure("一括取得で要求していない属性を取り出した: \(name)")
            }
            return nil
        }
    }

    /// 位置と大きさの差が、どれも 1pt 以内か（D-9）。
    static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameMatchTolerance
            && abs(lhs.origin.y - rhs.origin.y) <= frameMatchTolerance
            && abs(lhs.size.width - rhs.size.width) <= frameMatchTolerance
            && abs(lhs.size.height - rhs.size.height) <= frameMatchTolerance
    }
}

// MARK: - メニューの根を決める

/// `AppCollectionJob` のうち、前面のアプリのメニューバーと開いているメニューの根を決める部分（型の本体が長くなるため分けた）。
extension AppCollectionJob {
    /// 開いているメニューとシートを探すとき、候補の要素（ヒットテストで得た要素とその祖先、ウィンドウの子）で
    /// 1 回の IPC で読む属性。
    static let candidateNodeAttributes: [String] = [
        kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute,
    ]
    /// ヒットテストで得た要素から `AXMenu` を探して辿る親の数の上限。メニューの中のヒットは `AXMenuItem`（またはその
    /// 中の要素）なので、通常は 1〜2 回で着く。上限は、メニューでないポップアップで根まで辿り続けないため。
    static let menuSearchParentLimit = 3

    /// 前面のアプリの、開いているメニュー（前面から順）とメニューバーの根を返す（design.md 8.1 手順 2、D-31）。
    /// 前面のアプリでなければ空。対応付けの内訳は `state.menuReport` に残す。
    private func resolveMenuRoots(
        state: inout JobState,
        issues: AXAttributeIssueCounter
    ) throws(JobInterruption) -> [WalkRoot] {
        guard let menus = plan.menus else { return [] }
        let app = makeApplicationElement()
        var report = MenuRootReport(
            popUpMenuWindowCount: menus.popUpMenuWindows.count,
            popUpMenuRootCount: 0,
            menuBarWindowCount: menus.menuBarWindows.count,
            hasMenuBarRoot: false
        )
        // 途中で打ち切られても、それまでの内訳は残す
        defer { state.menuReport = report }

        var roots: [WalkRoot] = []
        for target in menus.popUpMenuWindows {
            guard let root = try resolvePopUpMenuRoot(target, app: app, state: &state, issues: issues) else { continue }
            roots.append(root)
            report.popUpMenuRootCount += 1
        }
        if let root = try resolveMenuBarRoot(menus.menuBarWindows, app: app, state: &state, issues: issues) {
            roots.append(root)
            report.hasMenuBarRoot = true
        }
        return roots
    }

    /// `AXMenuBar` を読み、frame が一致するメニューバーのウィンドウの `WindowID` の根にする。
    ///
    /// 一致するウィンドウがなければ根にしない（メニューバーを自動的に隠していて画面にない、別のディスプレイの
    /// メニューバーだけが見えている、など）。見えていないメニューバーの項目にラベルを付けないため。
    private func resolveMenuBarRoot(
        _ windows: [WindowTarget],
        app: AXElementRef,
        state: inout JobState,
        issues: AXAttributeIssueCounter
    ) throws(JobInterruption) -> WalkRoot? {
        guard !windows.isEmpty else { return nil }
        try checkBeforeIPC()
        let value: CFTypeRef
        do throws(AccessibilityReadError) {
            try setTimeoutIfNeeded(on: app)
            value = try client.attributeValue(kAXMenuBarAttribute, of: app)
        } catch .attributeUnsupported {
            // メニューバーを持たないアプリ（エージェント型のアプリなど）。走査するものがないだけで、失敗ではない
            return nil
        } catch {
            try state.fail(error)
            return nil
        }
        state.succeeded()
        guard let menuBar = Self.element(value, attribute: kAXMenuBarAttribute),
            let frame = try readWindowFrame(menuBar, state: &state, issues: issues),
            let target = windows.first(where: { Self.framesMatch(frame, $0.window.frame.rect) })
        else { return nil }
        return WalkRoot(element: menuBar, windowID: target.window.id, clip: target.clip)
    }

    /// 開いているメニューのウィンドウの中心を AX でヒットテストし、その要素か祖先の `AXMenu` を根にする。
    ///
    /// ヒットテストにしたのは、メニューバーのメニュー・サブメニュー・コンテキストメニューを同じ方法で見つけるため
    /// （AX ツリーでの位置がそれぞれ違う。メニューバーの項目の子、メニューの項目の子、アプリの子）。
    /// アプリの要素でヒットテストするので、前面にある Tobe のオーバーレイには当たらない。
    /// `AXMenu` が見つからない（メニューでないポップアップ）か、frame がウィンドウと 1pt 以内で一致しなければ根にしない。
    private func resolvePopUpMenuRoot(
        _ target: WindowTarget,
        app: AXElementRef,
        state: inout JobState,
        issues: AXAttributeIssueCounter
    ) throws(JobInterruption) -> WalkRoot? {
        let windowFrame = target.window.frame.rect
        try checkBeforeIPC()
        var current: AXElementRef
        do throws(AccessibilityReadError) {
            try setTimeoutIfNeeded(on: app)
            current = try Self.element(at: CGPoint(x: windowFrame.midX, y: windowFrame.midY), in: app)
        } catch .attributeUnsupported {
            // その位置にこのアプリの要素がない（.noValue）。メニューとして扱えないだけで、失敗ではない
            return nil
        } catch {
            try state.fail(error)
            return nil
        }
        state.succeeded()

        for _ in 0...Self.menuSearchParentLimit {
            guard let node = try readCandidateNode(current, state: &state, issues: issues) else { return nil }
            if node.role == kAXMenuRole {
                guard let frame = node.frame, Self.framesMatch(frame, windowFrame) else { return nil }
                return WalkRoot(element: current, windowID: target.window.id, clip: target.clip)
            }
            guard let parent = node.parent else { return nil }
            current = parent
        }
        return nil
    }

    /// `AXMenu` と `AXSheet` を探すために読む 1 要素の属性。
    private struct CandidateNode {
        let role: String?
        let frame: CGRect?
        let parent: AXElementRef?
    }

    /// 候補の要素の、ロール・frame・親を 1 回の IPC で読む。読めなければ nil。
    private func readCandidateNode(
        _ element: AXElementRef,
        state: inout JobState,
        issues: AXAttributeIssueCounter
    ) throws(JobInterruption) -> CandidateNode? {
        try checkBeforeIPC()
        do throws(AccessibilityReadError) {
            try setTimeoutIfNeeded(on: element)
            let values = try client.attributeValues(Self.candidateNodeAttributes, of: element)
            state.succeeded()
            let role = try Self.slot(kAXRoleAttribute, issues: issues) { () throws(AXValueDecodingError) in
                try values.string(kAXRoleAttribute)
            }
            let position = try Self.slot(kAXPositionAttribute, issues: issues) { () throws(AXValueDecodingError) in
                try values.point(kAXPositionAttribute)
            }
            let size = try Self.slot(kAXSizeAttribute, issues: issues) { () throws(AXValueDecodingError) in
                try values.size(kAXSizeAttribute)
            }
            let parentValue = try Self.slot(kAXParentAttribute, issues: issues) { () throws(AXValueDecodingError) in
                try values.raw(kAXParentAttribute)
            }
            let frame = position.flatMap { position in size.map { CGRect(origin: position, size: $0) } }
            return CandidateNode(
                role: role,
                frame: frame,
                parent: parentValue.flatMap { Self.element($0, attribute: kAXParentAttribute) }
            )
        } catch {
            try state.fail(error)
            return nil
        }
    }

    /// 1 つの `AXUIElement` の値（`AXMenuBar`、`AXParent`）を `AXElementRef` にする。
    ///
    /// `AXValueDecoder` には 1 要素の変換がないため、ここで持つ（T41 の申し送り）。型の確認は `AXValueDecoder` と同じく
    /// `CFGetTypeID` で行い、`unsafeDowncast` する（CF 型には `as?` が常に成功してしまうため）。
    /// 一括取得の「その属性の失敗」（`AXValue`）は属性なしとして nil にする。それ以外の型は AX の仕様に反するので、
    /// 黙って捨てずにログに残す（型名と属性名だけ。要素の内容は出さない）。
    private static func element(_ value: CFTypeRef, attribute: String) -> AXElementRef? {
        let typeID = CFGetTypeID(value)
        guard typeID == AXUIElementGetTypeID() else {
            if typeID != AXValueGetTypeID() {
                let typeName = CFCopyTypeIDDescription(typeID) as String
                Log.collector.error("\(attribute, privacy: .public) の値が要素ではない: \(typeName, privacy: .public)")
            }
            return nil
        }
        return AXElementRef(raw: unsafeDowncast(value, to: AXUIElement.self))
    }

    /// `AXUIElementCopyElementAtPosition` で、アプリの要素のうち `point`（左上原点のグローバル座標）にあるものを得る。
    ///
    /// `AXClient` にヒットテストの口がないため、ここで呼ぶ（エラーの変換は `AXClient.check` の 1 か所を使う）。
    /// その位置に要素がないときは `.attributeUnsupported`（`.noValue` の変換）を投げる。
    private static func element(
        at point: CGPoint,
        in app: AXElementRef
    ) throws(AccessibilityReadError) -> AXElementRef {
        var element: AXUIElement?
        try AXClient.check(AXUIElementCopyElementAtPosition(app.raw, Float(point.x), Float(point.y), &element))
        guard let element else { throw AXClient.readError(for: .noValue) }
        return AXElementRef(raw: element)
    }
}

// MARK: - シートの根を決める

/// `AppCollectionJob` のうち、シート（`AXSheet`）の根を決める部分（型の本体が長くなるため分けた）。
extension AppCollectionJob {
    /// ウィンドウのシートの一覧。SDK に定数がない属性なので名前で持つ。持たないアプリでは `AXChildren` を使う。
    static let sheetsAttribute = "AXSheets"
    /// シートを探すとき、照合した AX ウィンドウで 1 回の IPC で読む属性。
    static let sheetListAttributes: [String] = [sheetsAttribute, kAXChildrenAttribute]

    /// 対応する AX ウィンドウがない CG のウィンドウを、照合した AX ウィンドウ（前面から順）のシートと照合し、
    /// 一致したら `matched` のその位置にシートの根を入れる。
    ///
    /// シートは CG では別のウィンドウなので、`AXWindows` との照合では対応付かずに残る。残りがないときは何も読まない
    /// （シートを開いていない、ほとんどの場合に IPC を増やさないため）。シートの CG のウィンドウは親と同じレイヤー 0 で、
    /// `plan.targets` に入っている（覆われている・画面外なら、走査しなくてよいので入っていない）。
    ///
    /// 親ウィンドウの根からもシートの中は辿るが、その要素は親の `WindowID` に属し、前面のシートのウィンドウに覆われて
    /// 遮蔽で除かれるので、ラベルは二重にならない（8.6）。
    private func resolveSheetRoots(
        _ matched: inout [WalkRoot?],
        state: inout JobState,
        issues: AXAttributeIssueCounter
    ) throws(JobInterruption) {
        guard matched.contains(where: { $0 == nil }) else { return }
        let parents = matched.compactMap(\.self)
        guard !parents.isEmpty else { return }
        var report = SheetRootReport()
        // 途中で打ち切られても、それまでの内訳は残す
        defer { state.sheetReport = report }

        for parent in parents where matched.contains(where: { $0 == nil }) {
            guard let list = try readSheetCandidates(of: parent.element, state: &state, issues: issues) else {
                continue
            }
            report.record(list.source)
            for candidate in list.elements where matched.contains(where: { $0 == nil }) {
                guard let node = try readCandidateNode(candidate, state: &state, issues: issues),
                    node.role == kAXSheetRole,
                    let frame = node.frame
                else { continue }
                let index = plan.targets.indices.first { index in
                    matched[index] == nil && Self.framesMatch(frame, plan.targets[index].window.frame.rect)
                }
                guard let index else { continue }
                let target = plan.targets[index]
                matched[index] = WalkRoot(element: candidate, windowID: target.window.id, clip: target.clip)
                report.rootCount += 1
            }
        }
    }

    /// シートの候補の一覧と、どの属性から得たか。
    private struct SheetCandidates {
        let source: SheetListSource
        let elements: [AXElementRef]
    }

    /// AX ウィンドウのシートの候補を読む。`AXSheets` があればそれ、なければ `AXChildren`（ロールは呼び出し側で確かめる）。
    /// どちらも読めなければ nil。
    private func readSheetCandidates(
        of window: AXElementRef,
        state: inout JobState,
        issues: AXAttributeIssueCounter
    ) throws(JobInterruption) -> SheetCandidates? {
        try checkBeforeIPC()
        do throws(AccessibilityReadError) {
            try setTimeoutIfNeeded(on: window)
            let values = try client.attributeValues(Self.sheetListAttributes, of: window)
            state.succeeded()
            if let sheets = try Self.slot(
                Self.sheetsAttribute, issues: issues,
                { () throws(AXValueDecodingError) in
                    try values.elements(Self.sheetsAttribute)
                })
            {
                return SheetCandidates(source: .sheetsAttribute, elements: sheets)
            }
            let children = try Self.slot(kAXChildrenAttribute, issues: issues) { () throws(AXValueDecodingError) in
                try values.elements(kAXChildrenAttribute)
            }
            return children.map { SheetCandidates(source: .children, elements: $0) }
        } catch {
            try state.fail(error)
            return nil
        }
    }
}

/// シートの候補を得た属性。
private enum SheetListSource {
    case sheetsAttribute
    case children
}

/// アプリ 1 つの走査を途中で止める理由（`WalkStopReason` のうち `completed` 以外）。
private struct JobInterruption: Error {
    let reason: WalkStopReason
}

/// アプリ 1 つの走査の、根を決める段階の読み取りの記録。
private struct JobState {
    /// 根を決める段階と `TreeWalker` の読み取りの失敗の件数（`CollectionDiagnostic.readFailed` の元）。
    var readErrors: [AccessibilityReadError: Int] = [:]
    /// AX ウィンドウかシートと対応付いて根になったウィンドウの数（メニューの根は含めない）。
    var windowRootCount = 0
    /// 前面のアプリだけ。メニューの根の対応付けの内訳。
    var menuReport: MenuRootReport?
    /// シートを探したときだけ。シートの根の対応付けの内訳。
    var sheetReport: SheetRootReport?
    private var consecutiveCannotComplete = 0

    mutating func succeeded() {
        consecutiveCannotComplete = 0
    }

    /// 読み取りの失敗を数え、アプリの走査を続けられないなら投げる（design.md 8.7）。
    mutating func fail(_ error: AccessibilityReadError) throws(JobInterruption) {
        readErrors[error, default: 0] += 1
        switch error {
        case .apiDisabled:
            throw JobInterruption(reason: .apiDisabled)
        case .cannotComplete:
            consecutiveCannotComplete += 1
            if consecutiveCannotComplete >= TreeWalkerLimits.consecutiveCannotCompleteLimit {
                throw JobInterruption(reason: .unresponsive)
            }
        case .invalidElement, .attributeUnsupported, .actionUnsupported, .notImplemented, .other:
            consecutiveCannotComplete = 0
        }
    }
}

/// 走査の根（AX ウィンドウ）と、その要素が属する CG のウィンドウ。
private struct WalkRoot {
    let element: AXElementRef
    let windowID: WindowID
    let clip: GlobalRect
}

/// 走査で見つけた要素。`ElementHandleRegistry` に登録してから `CollectedElement` にする。
private struct AppHit: Sendable {
    let element: AXElementRef
    let windowID: WindowID
    let frame: GlobalRect
    let role: String
}

/// アプリ 1 つの走査の結果。
private struct AppCollection: Sendable {
    let hits: [AppHit]
    let report: AppCollectionReport

    var stopReason: WalkStopReason { report.stopReason }

    /// `CollectionResult.diagnostics` に入れる記録（design.md 8.5「部分的な結果」、8.7）。
    var diagnostics: [CollectionDiagnostic] {
        let pid = report.pid
        var diagnostics: [CollectionDiagnostic] = []
        switch report.stopReason {
        case .deadline:
            diagnostics.append(.deadlineExceeded(pid, collected: hits.count))
        case .nodeBudget:
            diagnostics.append(.nodeBudgetExhausted(pid))
        case .unresponsive:
            diagnostics.append(.unresponsive(pid))
        case .completed, .cancelled, .apiDisabled:
            // キャンセルと権限の取り消しは、収集全体の失敗（CollectionError）として投げる
            break
        }
        diagnostics += report.sortedReadErrors.map { error, count in .readFailed(pid, error, count: count) }
        return diagnostics
    }
}

// MARK: - 内訳（ログ用）

/// 1 回の収集の内訳。ログ（`Log.collector`）と Debug の `--collect-once` に使う。
///
/// 要素のタイトルや値、アプリ名は持たない。PID・件数・時間・終了理由・エラーの種類・属性名だけなので、
/// `logLines()` の行は public でログに出してよい（design.md 14 章）。
struct CollectionReport: Sendable {
    let elapsed: Duration
    let elementCount: Int
    /// 列挙した走査の対象のウィンドウ（レイヤー 0、Tobe 以外、alpha > 0）の数。
    let traversalTargetCount: Int
    /// 前面の 1 枚に完全に覆われていて走査しなかったウィンドウの数。
    let coveredWindowCount: Int
    /// 画面の外にあって走査しなかったウィンドウの数。
    let offscreenWindowCount: Int
    /// 有効なディスプレイが取れたか（取れなければ何も走査していない）。
    let hasScreens: Bool
    /// 前面のアプリから順。
    let apps: [AppCollectionReport]

    func logLines() -> [String] {
        var lines = [
            "収集: \(elapsed)、要素 \(elementCount) 件、アプリ \(apps.count) 件、"
                + "ウィンドウ \(traversalTargetCount) 件（覆われて省略 \(coveredWindowCount)、画面外 \(offscreenWindowCount)）"
                + (hasScreens ? "" : "、有効なディスプレイなし")
        ]
        for app in apps {
            lines += app.logLines()
        }
        return lines
    }
}

/// アプリ 1 つの走査の内訳。
struct AppCollectionReport: Sendable {
    let pid: ProcessID
    let hitCount: Int
    let visitedNodeCount: Int
    /// 走査しようとした CG のウィンドウの数。
    let targetWindowCount: Int
    /// AX ウィンドウかシートと対応付いて走査の根になった数（`targetWindowCount` との差は対応付かなかったウィンドウ）。
    /// シートの根を含む（内訳は `sheets`）。メニューの根は含めない（`menus`）。
    let rootCount: Int
    /// 前面のアプリだけ。メニューバーと開いているメニューの根の内訳（前面のアプリでなければ nil）。
    let menus: MenuRootReport?
    /// シートを探したときだけ（`AXWindows` と対応付かない CG のウィンドウが残ったとき）。シートの根の内訳。
    let sheets: SheetRootReport?
    let stopReason: WalkStopReason
    let readErrors: [AccessibilityReadError: Int]
    /// 「属性なし」として扱った読み取り（型の不一致など）。TobeCore の診断には入れず、ログにだけ出す（T41 の申し送り）。
    let issues: [AXAttributeIssue: Int]
    let elapsed: Duration

    /// 読み取りの失敗を、件数の多い順（同数ならエラーの名前順）に並べたもの。診断の並びを毎回同じにするため。
    var sortedReadErrors: [(AccessibilityReadError, Int)] {
        readErrors.map { ($0.key, $0.value) }.sorted { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 > rhs.1 : String(describing: lhs.0) < String(describing: rhs.0)
        }
    }

    func logLines() -> [String] {
        var lines = [
            "  pid \(pid.rawValue): ヒット \(hitCount) 件、ノード \(visitedNodeCount) 件、"
                + "根 \(rootCount)/\(targetWindowCount)、終了 \(stopReason)、\(elapsed)"
        ]
        if let menus {
            lines.append("    \(menus.logLine)")
        }
        if let sheets {
            lines.append("    \(sheets.logLine)")
        }
        for (error, count) in sortedReadErrors {
            lines.append("    readError \(error): \(count)")
        }
        for (issue, count) in issues.sorted(by: {
            $0.value != $1.value ? $0.value > $1.value : "\($0.key)" < "\($1.key)"
        }) {
            lines.append("    attributeIssue \(issue.description): \(count)")
        }
        return lines
    }
}

/// 前面のアプリの、メニューの根の対応付けの内訳（design.md 8.1 手順 2、D-31）。T49 の手動確認で、メニューが根に
/// なったかを `--collect-once` で見るためにログへ出す。
struct MenuRootReport: Sendable {
    /// 前面のアプリが所有する、開いているメニューのウィンドウの数。
    let popUpMenuWindowCount: Int
    /// そのうち `AXMenu` と対応付いて根になった数。
    var popUpMenuRootCount: Int
    /// 画面に見えているメニューバーのウィンドウの数（ディスプレイごと）。
    let menuBarWindowCount: Int
    /// `AXMenuBar` がメニューバーのウィンドウと対応付いて根になったか。
    var hasMenuBarRoot: Bool

    var logLine: String {
        "メニュー: メニューバー \(hasMenuBarRoot ? "あり" : "なし")（ウィンドウ \(menuBarWindowCount) 枚）、"
            + "開いているメニュー 根 \(popUpMenuRootCount)/\(popUpMenuWindowCount)"
    }
}

/// シートの根の対応付けの内訳。シートにラベルが付かないときに、シートが根になったか、どの属性から見つけたかを
/// `--collect-once` で見るためにログへ出す。
struct SheetRootReport: Sendable {
    /// `AXSheets` からシートの候補を読んだ AX ウィンドウの数。
    var sheetsAttributeWindowCount = 0
    /// `AXSheets` がなく、`AXChildren` からシートの候補を読んだ AX ウィンドウの数。
    var childrenWindowCount = 0
    /// CG のウィンドウと対応付いて根になったシートの数。
    var rootCount = 0

    fileprivate mutating func record(_ source: SheetListSource) {
        switch source {
        case .sheetsAttribute: sheetsAttributeWindowCount += 1
        case .children: childrenWindowCount += 1
        }
    }

    var logLine: String {
        "シート: 根 \(rootCount)、候補を読んだウィンドウ AXSheets \(sheetsAttributeWindowCount) 枚・"
            + "AXChildren \(childrenWindowCount) 枚"
    }
}
