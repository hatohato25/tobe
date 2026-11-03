import CoreGraphics

/// 走査の上限値（design.md 8.4、8.5）。V-5 の計測結果を見て調整する。
///
/// `TreeWalker` はジェネリックな型で static な格納プロパティを持てないため、別の型に置く。
public enum TreeWalkerLimits {
    /// 辿る深さの上限。根の深さを 0 とし、深さがこの値のノードの子は辿らない。
    public static let maxDepth = 50
    /// 1 回の IPC のタイムアウトの上限。期限までの残りがこれより短ければ、残りの時間を使う。
    public static let maxMessagingTimeout: Duration = .milliseconds(50)
    /// 1 アプリあたりのノード数の上限。同じアプリの複数の根で分け合う（`WalkResult.visitedNodeCount`）。
    public static let nodeBudgetPerApp = 4000
    /// `cannotComplete` がこの回数続いたら、そのアプリは応答しないとみなして打ち切る。
    public static let consecutiveCannotCompleteLimit = 2
}

/// 走査の手順のうち、ロールで決まる規則（design.md 8.4）。クリック可能の判定（`TraversalPolicy`）とは分けて持つ。
enum TreeWalkerRoles {
    /// 子を辿らないロール。ボタンなどの内部の要素にラベルが重複して付くのを防ぎ、IPC を減らす。
    static let leafRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXLink",
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXStaticText",
        "AXImage",
        "AXScrollBar",
        "AXValueIndicator",
    ]

    /// 子のクリップを自分の frame で狭めるロール（見える範囲が自分の frame に限られるもの）。
    static let clipNarrowingRoles: Set<String> = ["AXWindow", "AXScrollArea"]

    /// `AXChildren` の代わりに可視の子を読むロール。何千行もある表で、見えない行を 1 行ずつ読むのを避けるため。
    static func visibleChildrenAttribute(for role: String?) -> VisibleChildrenAttribute? {
        switch role {
        case "AXTable", "AXOutline": .visibleRows
        case "AXList": .visibleChildren
        default: nil
        }
    }
}

/// AX ツリーを幅優先で走査し、クリック可能な要素を集める（design.md 8.4、F-2.9、N-1.3）。
///
/// 期限が近くても手前（浅い階層）の要素から集まるよう、深さ優先ではなく幅優先にする。
/// IPC はブロッキングするため、呼び出し側は Swift Concurrency の協調スレッドプールではなく
/// GCD のキューで `walk` を呼ぶ（D-12）。
public struct TreeWalker<Source: AccessibilityTreeSource>: Sendable {
    public typealias Node = Source.Node

    private let source: Source
    private let policy: TraversalPolicy
    private let now: @Sendable () -> ContinuousClock.Instant

    /// - Parameter now: 現在時刻。テストでフェイクの時計に差し替えるため、`ContinuousClock` を直接使わない。
    public init(source: Source, policy: TraversalPolicy, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.source = source
        self.policy = policy
        self.now = now
    }

    /// `root` から走査する。
    ///
    /// - Parameters:
    ///   - clip: 根のクリップ矩形（ウィンドウの frame と画面の和集合の積）。これと交差しない要素は子孫ごと辿らない。
    ///   - deadline: これを過ぎたら新しい IPC を始めずに打ち切る。
    ///   - nodeBudget: `readNode` を試みるノード数の上限。
    ///   - isCancelled: IPC の前ごとに確認する。true なら打ち切る。
    public func walk(
        root: Node,
        clip: GlobalRect,
        deadline: ContinuousClock.Instant,
        nodeBudget: Int,
        isCancelled: () -> Bool
    ) -> WalkResult<Node> {
        // isCancelled は walk の間だけ使い、外に持ち出さない。内部の関数に値として渡すためだけにエスケープ可能にする
        withoutActuallyEscaping(isCancelled) { isCancelled in
            let context = ReadContext(deadline: deadline, isCancelled: isCancelled)
            var state = WalkState<Node>()
            var queue = [PendingNode(node: root, clip: clip.rect, depth: 0)]
            // 先頭からの取り出しを O(1) にするため、配列を詰めずに読み出し位置を進める
            var head = 0
            while head < queue.count {
                guard state.visitedNodeCount < nodeBudget else { return state.result(.nodeBudget) }
                let entry = queue[head]
                head += 1
                switch visit(entry, state: &state, context: context) {
                case .stop(let reason):
                    return state.result(reason)
                case .enqueue(let children):
                    queue.append(contentsOf: children)
                }
            }
            return state.result(.completed)
        }
    }

    // MARK: - 1 ノードの処理

    private func visit(
        _ entry: PendingNode<Node>,
        state: inout WalkState<Node>,
        context: ReadContext
    ) -> VisitOutcome<Node> {
        let snapshot: NodeSnapshot<Node>
        switch readSnapshot(of: entry.node, state: &state, context: context) {
        case .value(let value): snapshot = value
        case .stop(let reason): return .stop(reason)
        // 読めなかったノード（消えた要素など）は子孫も含めて飛ばす（design.md 8.7）
        case .failed: return .enqueue([])
        }

        // 面積 0 のコンテナ（SwiftUI などで見られる）や frame が取れないノードは、子だけが実際の位置を持つことが
        // あるため、枝刈りせず、クリップも狭めずに子を辿る
        let areaFrame = snapshot.frame.flatMap { $0.rect.width > 0 && $0.rect.height > 0 ? $0.rect : nil }
        if let areaFrame, !areaFrame.intersects(entry.clip) {
            return .enqueue([])
        }

        if let reason = recordHitIfClickable(entry.node, snapshot: snapshot, state: &state, context: context) {
            return .stop(reason)
        }

        guard entry.depth < TreeWalkerLimits.maxDepth else { return .enqueue([]) }
        let children: [Node]
        switch childNodes(of: entry.node, snapshot: snapshot, state: &state, context: context) {
        case .value(let value): children = value
        case .stop(let reason): return .stop(reason)
        case .failed: children = []
        }

        let childClip = Self.childClip(parentClip: entry.clip, role: snapshot.role, areaFrame: areaFrame)
        return .enqueue(children.map { PendingNode(node: $0, clip: childClip, depth: entry.depth + 1) })
    }

    private func readSnapshot(
        of node: Node,
        state: inout WalkState<Node>,
        context: ReadContext
    ) -> ReadOutcome<NodeSnapshot<Node>> {
        switch messagingTimeout(context) {
        case .success(let timeout):
            // 失敗したノードも上限に数える（読もうとする IPC の回数を抑えるための上限なので）
            state.visitedNodeCount += 1
            return perform(state: &state, timeout: timeout) { timeout throws(AccessibilityReadError) in
                try source.readNode(node, timeout: timeout)
            }
        case .failure(let stop):
            return .stop(stop.reason)
        }
    }

    /// 子のクリップ。`AXWindow` と `AXScrollArea` は、見える範囲が自分の frame に限られるので狭める。
    ///
    /// - Parameter areaFrame: 面積を持つ frame。面積 0 または frame がないノードはクリップを狭めない。
    private static func childClip(parentClip: CGRect, role: String?, areaFrame: CGRect?) -> CGRect {
        guard let areaFrame, let role, TreeWalkerRoles.clipNarrowingRoles.contains(role) else { return parentClip }
        // 呼び出し側で交差を確認済みなので、積は空にならない
        return parentClip.intersection(areaFrame)
    }

    /// クリック可能ならヒットとして記録する。打ち切る場合だけ理由を返す。
    private func recordHitIfClickable(
        _ node: Node,
        snapshot: NodeSnapshot<Node>,
        state: inout WalkState<Node>,
        context: ReadContext
    ) -> WalkStopReason? {
        guard let role = snapshot.role, let frame = snapshot.frame else { return nil }
        switch policy.evaluate(role: role, isEnabled: snapshot.isEnabled, frame: frame) {
        case .clickable:
            state.hits.append(WalkHit(node: node, role: role, frame: frame))
        case .requiresPressAction:
            // アクション名を読む IPC は、曖昧なロールのときだけに抑える（D-10）
            let outcome = read(state: &state, context: context) { timeout throws(AccessibilityReadError) in
                try source.readActionNames(node, timeout: timeout)
            }
            switch outcome {
            case .value(let actionNames):
                if policy.hasPressAction(actionNames) {
                    state.hits.append(WalkHit(node: node, role: role, frame: frame))
                }
            case .stop(let reason):
                return reason
            // アクション名が読めなければ対象にしない（件数は readErrors に残る）。子は辿る
            case .failed:
                break
            }
        case .notClickable:
            break
        }
        return nil
    }

    /// 辿る子を決める。子の読み方はここだけで決める。
    ///
    /// V-2 で表の `AXChildren` が重いと分かり 2 段階方式（D-11）に切り替える場合は、`readNode` から `AXChildren` を
    /// 外し、`AccessibilityTreeSource` に子を読むメソッドを足して、下の `snapshot.children` をその呼び出しに置き換える。
    private func childNodes(
        of node: Node,
        snapshot: NodeSnapshot<Node>,
        state: inout WalkState<Node>,
        context: ReadContext
    ) -> ReadOutcome<[Node]> {
        if let role = snapshot.role, TreeWalkerRoles.leafRoles.contains(role) {
            return .value([])
        }
        guard let attribute = TreeWalkerRoles.visibleChildrenAttribute(for: snapshot.role) else {
            return .value(snapshot.children)
        }
        let outcome = read(state: &state, context: context) { timeout throws(AccessibilityReadError) in
            try source.readVisibleChildren(node, attribute: attribute, timeout: timeout)
        }
        // 可視の子の属性を持たない表・リスト（独自実装のものなど）は、行を取りこぼさないよう AXChildren を使う。
        // 属性がなかったことは readErrors に残る
        if case .failed(.attributeUnsupported) = outcome {
            return .value(snapshot.children)
        }
        return outcome
    }

    // MARK: - IPC の共通処理

    /// 期限・キャンセルを確認してから 1 回の IPC を行い、エラーを数えて走査での扱いを決める（design.md 8.7）。
    private func read<Value>(
        state: inout WalkState<Node>,
        context: ReadContext,
        _ body: (Duration) throws(AccessibilityReadError) -> Value
    ) -> ReadOutcome<Value> {
        switch messagingTimeout(context) {
        case .success(let timeout): perform(state: &state, timeout: timeout, body)
        case .failure(let stop): .stop(stop.reason)
        }
    }

    /// 次の IPC のタイムアウト。キャンセルされているか、期限を過ぎていれば打ち切りの理由を返す。
    private func messagingTimeout(_ context: ReadContext) -> Result<Duration, StopBeforeRead> {
        if context.isCancelled() { return .failure(StopBeforeRead(reason: .cancelled)) }
        let remaining = now().duration(to: context.deadline)
        // 期限を過ぎてから IPC を始めない。待つのは実行中の IPC 1 回分だけにする（N-1.3）
        guard remaining > .zero else { return .failure(StopBeforeRead(reason: .deadline)) }
        return .success(min(TreeWalkerLimits.maxMessagingTimeout, remaining))
    }

    private func perform<Value>(
        state: inout WalkState<Node>,
        timeout: Duration,
        _ body: (Duration) throws(AccessibilityReadError) -> Value
    ) -> ReadOutcome<Value> {
        do {
            let value = try body(timeout)
            state.consecutiveCannotComplete = 0
            return .value(value)
        } catch {
            state.readErrors[error, default: 0] += 1
            switch error {
            case .apiDisabled:
                return .stop(.apiDisabled)
            case .cannotComplete:
                state.consecutiveCannotComplete += 1
                if state.consecutiveCannotComplete >= TreeWalkerLimits.consecutiveCannotCompleteLimit {
                    return .stop(.unresponsive)
                }
            case .invalidElement, .attributeUnsupported, .actionUnsupported, .notImplemented, .other:
                // 相手のアプリは応答しているので、「続けて cannotComplete」の数え直しをする
                state.consecutiveCannotComplete = 0
            }
            return .failed(error)
        }
    }
}

// MARK: - 走査中の状態

private struct PendingNode<Node: Sendable> {
    let node: Node
    let clip: CGRect
    let depth: Int
}

private struct WalkState<Node: Sendable> {
    var hits: [WalkHit<Node>] = []
    var readErrors: [AccessibilityReadError: Int] = [:]
    var consecutiveCannotComplete = 0
    var visitedNodeCount = 0

    func result(_ reason: WalkStopReason) -> WalkResult<Node> {
        WalkResult(hits: hits, stopReason: reason, readErrors: readErrors, visitedNodeCount: visitedNodeCount)
    }
}

/// 1 回の `walk` の間、変わらない値。`isCancelled` はエスケープしないクロージャのため、`walk` の外に持ち出さない。
private struct ReadContext {
    let deadline: ContinuousClock.Instant
    let isCancelled: () -> Bool
}

/// IPC を始める前に打ち切る理由（`Result` の失敗側に置くため `Error` にする）。
private struct StopBeforeRead: Error {
    let reason: WalkStopReason
}

private enum ReadOutcome<Value> {
    case value(Value)
    /// 読めなかったが、走査は続ける。
    case failed(AccessibilityReadError)
    case stop(WalkStopReason)
}

private enum VisitOutcome<Node: Sendable> {
    case enqueue([PendingNode<Node>])
    case stop(WalkStopReason)
}
