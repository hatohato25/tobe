import Foundation

/// AX ツリーの 1 ノードを読み取る口（design.md 3.5、8.3）。App 側の `AXTreeSource` が `AXUIElement` で実装する。
///
/// 走査の手順（`TreeWalker`）を TobeCore でテストできるよう、OS に依存する読み取りだけをここに切り出す。
/// どのメソッドも 1 回の IPC に対応し、呼び出し側（`TreeWalker`）が期限から計算した `timeout` を渡す。
/// 実装は、読む前にその要素のメッセージングのタイムアウトを `timeout` に設定する（design.md 8.5）。
public protocol AccessibilityTreeSource: Sendable {
    associatedtype Node: Sendable

    /// 1 回の IPC で `AXRole` / `AXSubrole` / `AXPosition` / `AXSize` / `AXEnabled` / `AXChildren` を読む（D-11）。
    ///
    /// 個々の属性が取れなかった場合は、その項目を nil（子は空）にして返す。ノード自体が読めなかった場合だけ投げる。
    func readNode(_ node: Node, timeout: Duration) throws(AccessibilityReadError) -> NodeSnapshot<Node>

    /// `AXVisibleRows`（表、アウトライン）または `AXVisibleChildren`（リスト）を読む。
    /// 属性を持たない要素では `AccessibilityReadError.attributeUnsupported` を投げる。
    func readVisibleChildren(
        _ node: Node,
        attribute: VisibleChildrenAttribute,
        timeout: Duration
    ) throws(AccessibilityReadError) -> [Node]

    /// `AXActionNames` を読む。`TraversalPolicy.evaluate` が `.requiresPressAction` を返したときだけ呼ばれる（D-10）。
    func readActionNames(_ node: Node, timeout: Duration) throws(AccessibilityReadError) -> [String]
}

/// `AccessibilityTreeSource.readNode` で読んだ 1 ノード分の属性。
///
/// 要素のタイトルや値は個人情報を含みうるため読まない（ログにも出さない）。
public struct NodeSnapshot<Node: Sendable>: Sendable {
    public let role: String?
    public let subrole: String?
    /// `AXPosition` と `AXSize` の両方が取れたときだけ値を持つ。
    public let frame: GlobalRect?
    /// `AXEnabled`。属性を持たない要素では nil。
    public let isEnabled: Bool?
    /// `AXChildren`。表・アウトライン・リストでは `TreeWalker` が使わず、可視の子を読み直す（design.md 8.3）。
    public let children: [Node]

    public init(role: String?, subrole: String?, frame: GlobalRect?, isEnabled: Bool?, children: [Node]) {
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.isEnabled = isEnabled
        self.children = children
    }
}

/// 可視の子を表す属性。
public enum VisibleChildrenAttribute: Hashable, Sendable {
    /// `AXVisibleRows`（`AXTable`、`AXOutline`）。
    case visibleRows
    /// `AXVisibleChildren`（`AXList`）。
    case visibleChildren
}
