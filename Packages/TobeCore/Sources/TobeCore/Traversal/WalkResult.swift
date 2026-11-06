import Foundation

/// 走査で見つけたクリック可能な要素（ヒット）。
public struct WalkHit<Node: Sendable>: Sendable {
    /// App 側が `ElementHandleRegistry` に登録し、`ElementID` を割り当てる。
    public let node: Node
    public let role: String
    /// 要素の frame（クリップで切り詰めない）。
    public let frame: GlobalRect

    public init(node: Node, role: String, frame: GlobalRect) {
        self.node = node
        self.role = role
        self.frame = frame
    }
}

extension WalkHit: Equatable where Node: Equatable {}

/// 1 つの根（ウィンドウ、メニューバーなど）からの走査の結果。
///
/// 打ち切られた場合も、それまでに集めたヒットを返す（部分的な結果を使う。暫定 Q-14、design.md 8.5）。
public struct WalkResult<Node: Sendable>: Sendable {
    /// 走査を終えた理由。
    public typealias StopReason = WalkStopReason

    /// 幅優先で見つけた順（浅い階層から）。
    public let hits: [WalkHit<Node>]
    public let stopReason: StopReason
    /// 読み取りに失敗した回数（エラーの種類ごと）。`CollectionDiagnostic.readFailed` の元になる。
    public let readErrors: [AccessibilityReadError: Int]
    /// `readNode` を試みたノードの数（失敗したものを含む）。アプリ単位のノード数の上限を、同じアプリの
    /// 複数のウィンドウで分け合うため、呼び出し側は残りの上限から差し引いて次の根に渡す。
    public let visitedNodeCount: Int

    public init(
        hits: [WalkHit<Node>],
        stopReason: StopReason,
        readErrors: [AccessibilityReadError: Int],
        visitedNodeCount: Int
    ) {
        self.hits = hits
        self.stopReason = stopReason
        self.readErrors = readErrors
        self.visitedNodeCount = visitedNodeCount
    }
}

extension WalkResult: Equatable where Node: Equatable {}

/// 走査を終えた理由。App 側の収集処理が `CollectionDiagnostic` / `CollectionError` に変換する。
///
/// `WalkResult` はジェネリックな型で、中に入れ子にすると `Node` ごとに別の型になってしまうため、外に置く。
public enum WalkStopReason: Equatable, Sendable {
    /// 辿るべきノードをすべて辿った。
    case completed
    /// 期限を過ぎた（`CollectionDiagnostic.deadlineExceeded`）。
    case deadline
    /// ノード数の上限に達した（`CollectionDiagnostic.nodeBudgetExhausted`）。
    case nodeBudget
    /// `cannotComplete` が続いた（`CollectionDiagnostic.unresponsive`）。
    case unresponsive
    /// 呼び出し側がキャンセルした（`CollectionError.cancelled`）。
    case cancelled
    /// 権限が取り消された（`CollectionError.accessibilityNotTrusted`）。
    case apiDisabled
}
