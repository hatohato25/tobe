import CoreGraphics

/// AX 要素を「クリック可能」としてヒントの対象にするかの判定規則（design.md 8.2、F-2.8、D-10）。
///
/// アクション名（`AXActionNames`）を読むには追加の IPC が要るため、判定を 2 段階に分ける。
/// 1. `evaluate(role:isEnabled:frame:)` でロールと共通の除外条件を見る
/// 2. 結果が `.requiresPressAction` のときだけアクション名を読み、`hasPressAction(_:)` で決める
public struct TraversalPolicy: Sendable {
    /// 判定の 1 段階目の結果。
    public enum Decision: Equatable, Sendable {
        /// アクションを確認せずに対象にする（許可ロール）。
        case clickable
        /// `AXPress` を持つときだけ対象にする（曖昧ロール）。呼び出し側がアクション名を読む。
        case requiresPressAction
        /// 対象にしない。
        case notClickable
    }

    /// アクションを確認せずに対象にするロール。サブロール（`AXSwitch`、`AXTabButton`、`AXSearchField`、
    /// `AXSecureTextField` など）はロールが同じなので、サブロールでは分けない。
    /// `AXRow` は spec F-2 の「リスト項目」（Finder のリスト表示やサイドバー）を対象にするため含める。
    public static let allowedRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXLink",
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXDisclosureTriangle",
        "AXMenuItem",
        "AXMenuBarItem",
        "AXRow",
        "AXIncrementor",
        "AXColorWell",
    ]

    /// `AXPress` を持つときだけ対象にするロール。`AXCell` は、行（`AXRow`）と重複してラベルが付くのを防ぐため
    /// こちらに置く。`AXStaticText` は数が多くアクションを読む IPC が増えるため含めない（design.md 8.2）。
    public static let ambiguousRoles: Set<String> = [
        "AXGroup",
        "AXImage",
        "AXCell",
        "AXUnknown",
    ]

    /// 曖昧ロールを対象にするために必要なアクション名（`kAXPressAction`）。
    public static let pressAction = "AXPress"

    public init() {}

    /// ロールと共通の除外条件から、対象にするか（またはアクション名の確認が要るか）を決める。
    ///
    /// - Parameters:
    ///   - role: `AXRole`。読めなかった場合は nil で、対象にしない。
    ///   - isEnabled: `AXEnabled`。`false` のときだけ除外する（暫定 Q-13）。多くの要素は `AXEnabled` を
    ///     持たないため、nil（属性なし）は有効として扱う。
    ///   - frame: `AXPosition` と `AXSize` から作った frame。取れなかった場合は nil で、対象にしない
    ///     （代替クリックで押す位置が決まらないため）。
    ///
    /// クリップ矩形と交差しない要素は、`TreeWalker` が子孫ごと枝刈りするため、ここでは見ない（design.md 8.4）。
    public func evaluate(role: String?, isEnabled: Bool?, frame: GlobalRect?) -> Decision {
        guard let role, let frame else { return .notClickable }
        if isEnabled == false { return .notClickable }
        // 幅または高さが 0 の要素は、ラベルを付けても押せない（SwiftUI などで見られる面積 0 のコンテナを含む）
        guard frame.rect.width > 0, frame.rect.height > 0 else { return .notClickable }
        if Self.allowedRoles.contains(role) { return .clickable }
        if Self.ambiguousRoles.contains(role) { return .requiresPressAction }
        return .notClickable
    }

    /// `evaluate` が `.requiresPressAction` を返した要素について、読んだアクション名から対象にするかを決める。
    public func hasPressAction(_ actionNames: [String]) -> Bool {
        actionNames.contains(Self.pressAction)
    }
}
