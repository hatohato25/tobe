// swiftlint:disable file_length
// 収集の段階（計画・アプリ 1 つの走査・内訳）を private の型でこのファイルに閉じ込めているため 400 行を超える。
// 別のファイルに分けると、これらの型を internal に開く必要がある（T42 の担当ファイルの制約もある）。

import ApplicationServices
import CoreGraphics
import Dispatch
import Synchronization
import TobiCore
import os

/// `ElementCollecting` の AX 実装。画面に見えているウィンドウを列挙し、アプリ単位で並列に AX ツリーを走査する
/// （design.md 8.1、8.4、8.5、8.7、13 章、D-9、D-12、D-29）。
///
/// 1 回の収集の流れ:
/// 1. 権限を確かめる（`AXIsProcessTrusted()`。未許可なら `CollectionError.accessibilityNotTrusted`）。
/// 2. `ElementHandleRegistry.beginCollection()` で前の収集の対応を消す。
/// 3. システム全体の IPC のタイムアウトを 50ms にする（`AXClient.applySystemWideMessagingTimeout()`。下の「タイムアウト」）。
/// 4. `WindowEnumerator` でウィンドウを列挙し、前面の 1 枚に完全に覆われたウィンドウと、画面の外にあるウィンドウを除く。
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
/// メニューバーと開いているメニューは走査しない（T58 で `AppCollectionJob.resolveRoots` に根を足す）。
/// 相手のアプリの AX を有効にする属性（Chromium・Electron 向けのもの）は書き込まない（F-2.7）。
///
/// スレッド: 状態は `registry`（ロック付き）だけなので、どの隔離から呼んでもよい。IPC はすべて GCD のキューで行い、
/// 呼び出し元（MainActor の Coordinator）や Swift Concurrency の協調スレッドプールをブロックしない。
struct AXElementCollector: ElementCollecting {
    private let client = AXClient()
    private let windowEnumerator = WindowEnumerator()
    private let policy = TraversalPolicy()
    private let registry: ElementHandleRegistry

    /// - Parameter registry: 収集した要素の対応表。同じものを `AXActionPerformer` に `registry.lookup` で渡す（T48）。
    init(registry: ElementHandleRegistry) {
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

        let snapshot = try await Self.runOnQueue { [windowEnumerator] in
            Result { () throws(CollectionError) in try windowEnumerator.enumerate() }
        }.get()
        let plan = CollectionPlan(snapshot: snapshot, screenUnion: Self.activeDisplayUnion())

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
                let job = AppCollectionJob(client: client, policy: policy, plan: app, deadline: deadline, flag: flag)
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

    init(snapshot: WindowListSnapshot, screenUnion: CGRect?) {
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
            // 根のクリップは、ウィンドウの frame と画面の和集合の積（design.md 8.4）
            let clip = screenUnion.map { window.frame.rect.intersection($0) } ?? .null
            guard !clip.isEmpty else {
                offscreen += 1
                continue
            }
            let target = WindowTarget(window: window, clip: GlobalRect(rect: clip))
            if let index = groupIndexByPID[window.ownerPID] {
                groups[index].targets.append(target)
            } else {
                groupIndexByPID[window.ownerPID] = groups.count
                groups.append(AppPlan(pid: window.ownerPID, targets: [target]))
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
    var targets: [WindowTarget]
}

/// 走査する CG のウィンドウと、その根のクリップ。
private struct WindowTarget: Sendable {
    let window: WindowInfo
    let clip: GlobalRect
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
/// 1. アプリの要素（収集ごとに作り直す）の `AXWindows` を読む。
/// 2. 各 AX ウィンドウの `AXPosition` / `AXSize` / `AXMinimized` を 1 回の IPC で読み、最小化されておらず、frame が
///    CG のウィンドウの bounds と 1pt 以内で一致するものを、その `WindowID` の根にする（D-9）。一致しない AX
///    ウィンドウ（別の Space、画面外など）は捨てる。CG のウィンドウがすべて対応付いたら、残りの AX ウィンドウは読まない。
/// 3. 根を前面から順に `TreeWalker` で走査する。ノード数の上限はアプリ単位なので、次の根には
///    「4000 − それまでの `visitedNodeCount` の合計」を渡す（design.md 8.4、T23）。
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
    let plan: AppPlan
    let deadline: ContinuousClock.Instant
    let flag: CancellationFlag

    func run() -> AppCollection {
        let clock = ContinuousClock()
        let start = clock.now
        let issues = AXAttributeIssueCounter()
        var state = JobState()
        var stopReason = WalkStopReason.completed
        var roots: [WalkRoot] = []
        do throws(JobInterruption) {
            roots = try resolveRoots(state: &state, issues: issues)
        } catch {
            stopReason = error.reason
        }

        var hits: [AppHit] = []
        var visited = 0
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
                nodeBudget: TreeWalkerLimits.nodeBudgetPerApp - visited,
                isCancelled: { flag.isCancelled }
            )
            visited += result.visitedNodeCount
            state.readErrors.merge(result.readErrors, uniquingKeysWith: +)
            hits += result.hits.map { hit in
                AppHit(element: hit.node, windowID: root.windowID, frame: hit.frame, role: hit.role)
            }
            guard result.stopReason == .completed else {
                stopReason = result.stopReason
                break
            }
        }

        let report = AppCollectionReport(
            pid: plan.pid,
            hitCount: hits.count,
            visitedNodeCount: visited,
            targetWindowCount: plan.targets.count,
            rootCount: roots.count,
            stopReason: stopReason,
            readErrors: state.readErrors,
            issues: issues.snapshot(),
            elapsed: start.duration(to: clock.now)
        )
        return AppCollection(hits: hits, report: report)
    }

    // MARK: 根を決める

    /// `AXWindows` を読み、CG のウィンドウと frame で対応付けた根を、CG のウィンドウの順（前面から）で返す。
    private func resolveRoots(
        state: inout JobState,
        issues: AXAttributeIssueCounter
    ) throws(JobInterruption) -> [WalkRoot] {
        // アプリの要素は収集ごとに作る。前の収集で設定した短いタイムアウトが残らない（T41 の前提）
        let app = AXElementRef.application(pid: plan.pid.rawValue)
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
        return matched.compactMap(\.self)
    }

    /// AX ウィンドウの frame（左上原点のグローバル座標）。最小化されている、読めない、位置か大きさがないときは nil。
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

/// アプリ 1 つの走査を途中で止める理由（`WalkStopReason` のうち `completed` 以外）。
private struct JobInterruption: Error {
    let reason: WalkStopReason
}

/// アプリ 1 つの走査の、根を決める段階の読み取りの記録。
private struct JobState {
    /// 根を決める段階と `TreeWalker` の読み取りの失敗の件数（`CollectionDiagnostic.readFailed` の元）。
    var readErrors: [AccessibilityReadError: Int] = [:]
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
    /// 列挙した走査の対象のウィンドウ（レイヤー 0、Tobi 以外、alpha > 0）の数。
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
    /// AX ウィンドウと対応付いて走査の根になった数（`targetWindowCount` との差は対応付かなかったウィンドウ）。
    let rootCount: Int
    let stopReason: WalkStopReason
    let readErrors: [AccessibilityReadError: Int]
    /// 「属性なし」として扱った読み取り（型の不一致など）。TobiCore の診断には入れず、ログにだけ出す（T41 の申し送り）。
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
