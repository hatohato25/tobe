import ApplicationServices
import Synchronization
import TobeCore

/// `AccessibilityTreeSource` の AX 実装（design.md 3.5、8.3、8.5、8.7）。`TreeWalker` が 1 ノードずつ読むのに使う。
///
/// 読み方:
/// - `readNode`: `AXUIElementCopyMultipleAttributeValues` 1 回で、`AXRole` / `AXSubrole` / `AXPosition` / `AXSize` /
///   `AXEnabled` / `AXChildren` を読む（D-11。V-2 の結果、子を別に読む 2 段階方式にはしない）。
/// - `readVisibleChildren`: 表・アウトラインは `AXVisibleRows`、リストは `AXVisibleChildren` を 1 回で読む。
///   属性がなければ `.attributeUnsupported` を投げ、`TreeWalker` が一括取得の `AXChildren` に切り替える（T23）。
/// - `readActionNames`: `AXUIElementCopyActionNames` を 1 回（曖昧ロールのときだけ呼ばれる。D-10）。
///
/// 型が合わない値（design.md 8.3）: 「属性なし」として扱い、`issues` に件数を記録する。`readNode` ではその項目を
/// nil（子は空）にし、`readVisibleChildren` / `readActionNames` では `.attributeUnsupported` を投げる。
///
/// タイムアウト（V-3、D-29）: `TreeWalker` が渡す `timeout`（50ms と期限までの残りの短いほう）が 50ms より短いとき
/// だけ、IPC の直前にその参照へ設定する。50ms のときは、起動時に設定したシステム全体の 50ms
/// （`AXClient.applySystemWideMessagingTimeout()`。T42 が呼ぶ）に任せる。
/// - 参照ごとの設定はシステム全体の設定より優先されるので、50ms を参照に書いても結果は同じ。1 ノードに 1〜3 回ある
///   設定の呼び出しを、期限が近いときだけに減らせる。
/// - `AXChildren` で受け取る子は毎回新しい参照（未設定 = システム全体の 50ms）なので、子を受け取るたびに設定し直す
///   必要はない。
/// - 1 回の走査の中では「期限までの残り」は減る一方なので、一度 50ms より短くなった後は、読むたびに設定される。
///   前提: 走査に使う参照を、別の収集（別の期限）の走査で使い回さない（古い短い設定が残るため）。
///
/// スレッド: 状態は `issues`（ロック付き）だけなので、どのスレッドからでも使える。IPC はブロッキングするため、
/// GCD のキューから呼ぶ（design.md 8.5）。収集ではアプリごとに 1 つ作り、走査が終わったら `issues` を読む。
struct AXTreeSource: AccessibilityTreeSource {
    typealias Node = AXElementRef

    /// `readNode` の一括取得で読む属性。並びは結果の取り出しに関係しない（属性名で取り出す）。
    static let nodeAttributes: [String] = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXEnabledAttribute,
        kAXChildrenAttribute,
    ]
    /// `readActionNames` の失敗を `AXAttributeIssue` に記録するときの名前（属性ではないが、診断で区別できるように）。
    static let actionNamesLabel = "AXActionNames"

    private let client: AXClient
    /// 型の不一致など、「属性なし」として扱った読み取りの件数。呼び出し側が診断に使う。
    let issues: AXAttributeIssueCounter

    init(client: AXClient, issues: AXAttributeIssueCounter) {
        self.client = client
        self.issues = issues
    }

    // MARK: - AccessibilityTreeSource

    func readNode(_ node: AXElementRef, timeout: Duration) throws(AccessibilityReadError) -> NodeSnapshot<AXElementRef>
    {
        try applyTimeout(timeout, to: node)
        let values = try client.attributeValues(Self.nodeAttributes, of: node)

        let role = try optionalValue(kAXRoleAttribute) { () throws(AXValueDecodingError) in
            try values.string(kAXRoleAttribute)
        }
        let subrole = try optionalValue(kAXSubroleAttribute) { () throws(AXValueDecodingError) in
            try values.string(kAXSubroleAttribute)
        }
        let position = try optionalValue(kAXPositionAttribute) { () throws(AXValueDecodingError) in
            try values.point(kAXPositionAttribute)
        }
        let size = try optionalValue(kAXSizeAttribute) { () throws(AXValueDecodingError) in
            try values.size(kAXSizeAttribute)
        }
        let isEnabled = try optionalValue(kAXEnabledAttribute) { () throws(AXValueDecodingError) in
            try values.bool(kAXEnabledAttribute)
        }
        let children = try optionalValue(kAXChildrenAttribute) { () throws(AXValueDecodingError) in
            try values.elements(kAXChildrenAttribute)
        }

        // AX の位置とサイズは、どちらも左上原点のグローバル座標（design.md 9.1）なので、そのまま矩形にする
        let frame = position.flatMap { position in
            size.map { size in GlobalRect(rect: CGRect(origin: position, size: size)) }
        }
        return NodeSnapshot(role: role, subrole: subrole, frame: frame, isEnabled: isEnabled, children: children ?? [])
    }

    func readVisibleChildren(
        _ node: AXElementRef,
        attribute: VisibleChildrenAttribute,
        timeout: Duration
    ) throws(AccessibilityReadError) -> [AXElementRef] {
        let name = Self.attributeName(of: attribute)
        try applyTimeout(timeout, to: node)
        let value = try client.attributeValue(name, of: node)
        return try requiredValue(name) { () throws(AXValueDecodingError) in
            try AXValueDecoder.elements(value)
        }
    }

    func readActionNames(_ node: AXElementRef, timeout: Duration) throws(AccessibilityReadError) -> [String] {
        try applyTimeout(timeout, to: node)
        let names = try client.actionNames(of: node)
        return try requiredValue(Self.actionNamesLabel) { () throws(AXValueDecodingError) in
            try AXValueDecoder.strings(names)
        }
    }

    // MARK: - 内部

    static func attributeName(of attribute: VisibleChildrenAttribute) -> String {
        switch attribute {
        case .visibleRows: kAXVisibleRowsAttribute
        case .visibleChildren: kAXVisibleChildrenAttribute
        }
    }

    /// 期限が近い（`timeout` が 50ms より短い）ときだけ、その参照にタイムアウトを設定する（D-29。型の説明を参照）。
    private func applyTimeout(_ timeout: Duration, to node: AXElementRef) throws(AccessibilityReadError) {
        guard timeout < AXClient.systemWideMessagingTimeout else { return }
        try client.setMessagingTimeout(timeout, for: node)
    }

    /// 一括取得の 1 項目を取り出す。「属性なし」として扱うものは nil にし、ノード自体の失敗だけを投げる。
    private func optionalValue<Value>(
        _ attribute: String,
        _ decode: () throws(AXValueDecodingError) -> Value
    ) throws(AccessibilityReadError) -> Value? {
        do {
            return try decode()
        } catch {
            try treatAsMissing(error, attribute: attribute)
            return nil
        }
    }

    /// 単独で読んだ値を変換する。「属性なし」として扱うものは `.attributeUnsupported` を投げる
    /// （可視の子なら `TreeWalker` が `AXChildren` に切り替える。アクション名ならヒットにしない）。
    private func requiredValue<Value>(
        _ attribute: String,
        _ decode: () throws(AXValueDecodingError) -> Value
    ) throws(AccessibilityReadError) -> Value {
        do {
            return try decode()
        } catch {
            try treatAsMissing(error, attribute: attribute)
            throw .attributeUnsupported
        }
    }

    /// 変換の失敗を「属性なし」として扱えるかを決める（design.md 8.3、8.7）。戻ったら、呼び出し側は属性なしとして扱う。
    ///
    /// - その属性が単にない（`.attributeUnsupported`）: 普通にあることなので記録しない。
    /// - 型が合わない、その属性だけの別の失敗（`.notImplemented` など）: 件数を記録する。
    /// - 要素や相手のアプリについての失敗（`.invalidElement` / `.cannotComplete` / `.apiDisabled`）が属性の位置に
    ///   入っていた: その属性だけの問題ではないので、ノードの失敗として投げる（`TreeWalker` が飛ばす・打ち切る）。
    private func treatAsMissing(_ error: AXValueDecodingError, attribute: String) throws(AccessibilityReadError) {
        switch error {
        case .typeMismatch(let expected, let actualTypeID):
            issues.record(.typeMismatch(attribute: attribute, expected: expected, actualTypeID: actualTypeID))
        case .attributeError(let readError):
            switch readError {
            case .attributeUnsupported:
                return
            case .invalidElement, .cannotComplete, .apiDisabled:
                throw readError
            case .actionUnsupported, .notImplemented, .other:
                issues.record(.attributeError(attribute: attribute, readError))
            }
        case .notRequested(let name):
            // nodeAttributes にない属性を取り出したときだけ起きる。このファイルの書き誤りなので、黙って属性なしにしない
            preconditionFailure("一括取得で要求していない属性を取り出した: \(name)")
        }
    }
}

/// 「属性なし」として扱った読み取りの理由（design.md 8.3。型が合わない値の件数を診断に残すため）。
///
/// 要素のタイトルや値は含まない。属性名と型の情報だけなので、ログに public で出してよい。
enum AXAttributeIssue: Hashable, Sendable, CustomStringConvertible {
    /// 値の型が期待と違った。`actualTypeID` は `CFCopyTypeIDDescription` で型名にできる。
    case typeMismatch(attribute: String, expected: AXValueKind, actualTypeID: CFTypeID)
    /// 一括取得のその属性の位置に、属性だけの失敗（`.notImplemented` / `.other` など）が入っていた。
    case attributeError(attribute: String, AccessibilityReadError)

    var description: String {
        switch self {
        case .typeMismatch(let attribute, let expected, let actualTypeID):
            "\(attribute): typeMismatch(expected: \(expected.rawValue), "
                + "actual: \(CFCopyTypeIDDescription(actualTypeID) as String))"
        case .attributeError(let attribute, let error):
            "\(attribute): attributeError(\(error))"
        }
    }
}

/// `AXAttributeIssue` の件数。`AXTreeSource` が記録し、走査の後に呼び出し側（収集、Debug コマンド）が読む。
///
/// `AccessibilityTreeSource` は `Sendable` で、`TreeWalker` は記録の口を持たないため、ロック付きの参照型で共有する。
/// 収集ではアプリごと（= 1 つの GCD のキュー）に 1 つ作るので、ロックが競合することはほぼない。
final class AXAttributeIssueCounter: Sendable {
    private let counts = Mutex<[AXAttributeIssue: Int]>([:])

    init() {}

    func record(_ issue: AXAttributeIssue) {
        counts.withLock { $0[issue, default: 0] += 1 }
    }

    /// 今までの件数。
    func snapshot() -> [AXAttributeIssue: Int] {
        counts.withLock { $0 }
    }
}
