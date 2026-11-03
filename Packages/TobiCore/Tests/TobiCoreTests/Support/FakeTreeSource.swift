import CoreGraphics
import Synchronization

@testable import TobiCore

/// テスト用の AX ノード。`name` をノードの識別子（`FakeTreeSource.Node`）として使う。
struct FakeNode: Sendable {
    var name: String
    var role: String?
    var frame: CGRect?
    var isEnabled: Bool?
    var actionNames: [String] = []
    var children: [FakeNode] = []
    /// `readVisibleChildren` が返す子の名前。nil なら `attributeUnsupported` を投げる。
    var visibleChildNames: [String]?
    /// `readNode` で投げるエラー。
    var readError: AccessibilityReadError?
    /// `readActionNames` で投げるエラー。
    var actionNamesError: AccessibilityReadError?
    /// `readVisibleChildren` で投げるエラー（`visibleChildNames` より優先）。
    var visibleChildrenError: AccessibilityReadError?

    init(
        _ name: String,
        role: String?,
        frame: CGRect?,
        isEnabled: Bool? = nil,
        actionNames: [String] = [],
        children: [FakeNode] = []
    ) {
        self.name = name
        self.role = role
        self.frame = frame
        self.isEnabled = isEnabled
        self.actionNames = actionNames
        self.children = children
    }
}

/// フェイクのソースが受けた呼び出し。走査の順序と、読まなかったノードを確かめるために記録する。
enum FakeTreeCall: Equatable {
    case readNode(String, timeout: Duration)
    case readVisibleChildren(String, VisibleChildrenAttribute)
    case readActionNames(String)
}

/// 進めた分だけ時刻が進むフェイクの時計。
final class FakeClock: Sendable {
    private let current = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant {
        current.withLock { $0 }
    }

    func advance(by duration: Duration) {
        current.withLock { $0 += duration }
    }

    /// 今の時刻から `duration` 後の時刻（期限を作るため）。
    func instant(after duration: Duration) -> ContinuousClock.Instant {
        now.advanced(by: duration)
    }
}

/// `FakeNode` の木から読み取る `AccessibilityTreeSource`。読むたびに `costPerRead` だけ時計を進める。
final class FakeTreeSource: AccessibilityTreeSource {
    typealias Node = String

    let clock: FakeClock
    private let nodes: [String: FakeNode]
    private let costPerRead: Duration
    private let recorded = Mutex<[FakeTreeCall]>([])

    init(root: FakeNode, clock: FakeClock = FakeClock(), costPerRead: Duration = .milliseconds(1)) {
        var nodes: [String: FakeNode] = [:]
        var pending = [root]
        while let node = pending.popLast() {
            precondition(nodes[node.name] == nil, "FakeNode の名前が重複している: \(node.name)")
            nodes[node.name] = node
            pending.append(contentsOf: node.children)
        }
        self.nodes = nodes
        self.clock = clock
        self.costPerRead = costPerRead
    }

    var calls: [FakeTreeCall] {
        recorded.withLock { $0 }
    }

    /// `readNode` を呼ばれたノードの名前（呼ばれた順）。
    var readNodeNames: [String] {
        calls.compactMap {
            if case .readNode(let name, _) = $0 { name } else { nil }
        }
    }

    func readNode(_ node: String, timeout: Duration) throws(AccessibilityReadError) -> NodeSnapshot<String> {
        let fake = try lookUp(node, call: .readNode(node, timeout: timeout))
        if let error = fake.readError { throw error }
        return NodeSnapshot(
            role: fake.role,
            subrole: nil,
            frame: fake.frame.map(GlobalRect.init(rect:)),
            isEnabled: fake.isEnabled,
            children: fake.children.map(\.name)
        )
    }

    func readVisibleChildren(
        _ node: String,
        attribute: VisibleChildrenAttribute,
        timeout: Duration
    ) throws(AccessibilityReadError) -> [String] {
        let fake = try lookUp(node, call: .readVisibleChildren(node, attribute))
        if let error = fake.visibleChildrenError { throw error }
        guard let names = fake.visibleChildNames else { throw .attributeUnsupported }
        return names
    }

    func readActionNames(_ node: String, timeout: Duration) throws(AccessibilityReadError) -> [String] {
        let fake = try lookUp(node, call: .readActionNames(node))
        if let error = fake.actionNamesError { throw error }
        return fake.actionNames
    }

    private func lookUp(_ name: String, call: FakeTreeCall) throws(AccessibilityReadError) -> FakeNode {
        recorded.withLock { $0.append(call) }
        clock.advance(by: costPerRead)
        // 木にない名前は、消えた要素として扱う
        guard let fake = nodes[name] else { throw .invalidElement }
        return fake
    }
}

// MARK: - TreeWalker のテスト用の組み立て

extension FakeNode {
    /// 根のクリップに使う画面の大きさ。
    static let screenRect = CGRect(x: 0, y: 0, width: 1000, height: 800)
    static let windowRect = CGRect(x: 0, y: 0, width: 800, height: 600)

    static func button(_ name: String, _ frame: CGRect = CGRect(x: 10, y: 10, width: 80, height: 24)) -> FakeNode {
        FakeNode(name, role: "AXButton", frame: frame)
    }

    /// `b1`、`b2` … と名付けたボタン。
    static func buttons(_ count: Int) -> [FakeNode] {
        (1...count).map { .button("b\($0)") }
    }

    /// `readNode` で `error` を投げる AXGroup。
    static func failing(_ name: String, _ error: AccessibilityReadError, children: [FakeNode] = []) -> FakeNode {
        var node = FakeNode(name, role: "AXGroup", frame: windowRect, children: children)
        node.readError = error
        return node
    }

    /// 名前が `"window"` の AXWindow。`FakeTreeSource.walk` の根になる。
    static func window(_ children: [FakeNode], frame: CGRect = windowRect) -> FakeNode {
        FakeNode("window", role: "AXWindow", frame: frame, children: children)
    }
}

extension FakeTreeSource {
    /// フェイクの時計で `"window"` から走査する。期限の既定値は十分先。
    func walk(
        clip: CGRect = FakeNode.screenRect,
        deadlineAfter: Duration = .seconds(10),
        nodeBudget: Int = 4000,
        isCancelled: () -> Bool = { false }
    ) -> WalkResult<String> {
        let clock = clock
        let walker = TreeWalker(source: self, policy: TraversalPolicy(), now: { clock.now })
        return walker.walk(
            root: "window",
            clip: GlobalRect(rect: clip),
            deadline: clock.instant(after: deadlineAfter),
            nodeBudget: nodeBudget,
            isCancelled: isCancelled
        )
    }
}
