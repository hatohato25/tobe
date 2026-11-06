import ApplicationServices
import TobiCore

/// AX の API の薄いラッパー（design.md 4 章、8.3、8.5、8.7）。
///
/// - どのメソッドも 1 回の IPC（タイムアウトの設定は IPC なし）に対応し、`AXError` を `AccessibilityReadError` に
///   変換して投げる。変換は `check(_:)` の 1 か所だけで行う（design.md 8.7 の表）。
/// - 値の型の変換は `AXValueDecoder` が行う。このラッパーは CF の値をそのまま返す（IPC の失敗と型の不一致を分けて
///   扱えるようにするため）。
/// - 状態を持たないので、どのスレッドからでも使える。IPC はブロッキングなので、MainActor や Swift Concurrency の
///   協調スレッドプールから大量に呼ばない（収集は GCD のキューで行う。design.md 8.5）。
///
/// タイムアウトの使い方（V-3、D-29）:
/// - 起動時に `applySystemWideMessagingTimeout()` を 1 回呼ぶ（T42）。要素ごとの設定をしていない参照すべてが 50ms になる。
/// - 期限が近いときだけ、IPC の直前に `setMessagingTimeout(_:for:)` でその参照に残り時間を設定する（T41）。
///   設定はその参照にだけ効き、`AXChildren` などで受け取る子の参照には引き継がれない。
/// - `press(_:)` は、その参照に 1.0 秒を設定してから `AXPress` する（システム全体の 50ms より優先される）。
struct AXClient: Sendable {
    /// システム全体のメッセージングのタイムアウト（design.md 8.5、D-29）。`TreeWalker` が渡す上限と同じ値にする。
    static let systemWideMessagingTimeout: Duration = TreeWalkerLimits.maxMessagingTimeout
    /// `AXPress` の前にその参照へ設定するタイムアウト（design.md 10 章、D-29）。
    static let pressMessagingTimeout: Duration = .seconds(1)

    // MARK: - 読み取り

    /// `AXUIElementCopyMultipleAttributeValues`（options 0）で、複数の属性を 1 回の IPC で読む（design.md 8.3）。
    ///
    /// 呼び出し全体の失敗だけを投げる。個々の属性の失敗は、結果の値（`kAXValueAXErrorType` の `AXValue`）として入り、
    /// `AXAttributeValues` の取り出しで `AXValueDecodingError.attributeError` になる。
    func attributeValues(
        _ attributes: [String],
        of element: AXElementRef
    ) throws(AccessibilityReadError) -> AXAttributeValues {
        var values: CFArray?
        try Self.check(
            AXUIElementCopyMultipleAttributeValues(
                element.raw,
                attributes as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0),
                &values
            )
        )
        // 成功なのに配列がない・数が合わないのは AX の仕様に反する。値の対応が崩れるので、黙って詰めずに全体を失敗にする
        guard let values else { throw Self.readError(for: .failure) }
        let items = Self.arrayItems(values)
        guard items.count == attributes.count else { throw Self.readError(for: .failure) }
        // 同じ属性を重ねて要求したときは、最初の位置の値を使う（AX は位置ごとに同じ値を返す）
        return AXAttributeValues(values: Dictionary(zip(attributes, items)) { first, _ in first })
    }

    /// `AXUIElementCopyAttributeValue` で、1 つの属性を読む（`AXVisibleRows`、`AXWindows` など）。
    ///
    /// 属性を持たない要素では `.attributeUnsupported` を投げる（`.noValue` も同じ。design.md 8.7）。
    func attributeValue(_ attribute: String, of element: AXElementRef) throws(AccessibilityReadError) -> CFTypeRef {
        var value: CFTypeRef?
        try Self.check(AXUIElementCopyAttributeValue(element.raw, attribute as CFString, &value))
        // 成功なのに値がないのは「値なし」と同じ意味なので、.noValue と同じ扱いにする
        guard let value else { throw Self.readError(for: .noValue) }
        return value
    }

    /// `AXUIElementCopyActionNames` で、要素のアクション名の `CFArray` を読む（曖昧なロールのときだけ。D-10）。
    ///
    /// 文字列の配列への変換は `AXValueDecoder.strings(_:)` で行う。アクションのない要素では空の配列が返る。
    func actionNames(of element: AXElementRef) throws(AccessibilityReadError) -> CFArray {
        var names: CFArray?
        try Self.check(AXUIElementCopyActionNames(element.raw, &names))
        // 成功なのに配列がないのは「値なし」と同じ意味なので、.noValue と同じ扱いにする
        guard let names else { throw Self.readError(for: .noValue) }
        return names
    }

    // MARK: - 操作

    /// その参照にタイムアウト 1.0 秒を設定してから `AXPress` する（design.md 10 章、D-29）。
    ///
    /// 押せない要素では `.actionUnsupported` を投げる（代替クリックへの切り替えは呼び出し側。T46、D-19）。
    func press(_ element: AXElementRef) throws(AccessibilityReadError) {
        try setMessagingTimeout(Self.pressMessagingTimeout, for: element)
        try Self.check(AXUIElementPerformAction(element.raw, kAXPressAction as CFString))
    }

    /// `AXUIElementSetAttributeValue` で、真偽値の属性を設定する（`ContentAccessibilityEnabler`）。
    func setAttribute(_ attribute: String, to value: Bool, of element: AXElementRef) throws(AccessibilityReadError) {
        try Self.check(AXUIElementSetAttributeValue(element.raw, attribute as CFString, value as CFBoolean))
    }

    // MARK: - タイムアウト

    /// その参照のメッセージングのタイムアウトを設定する（V-3: この参照にだけ効く）。プロセス内の設定で IPC は発生しない。
    ///
    /// `timeout` は正の値にする。0 は「既定（約 1.5 秒）に戻す」意味になり、期限を守れなくなるので受け付けず、
    /// `.other(code: kAXErrorIllegalArgument)` を投げる（負の値を AX に渡したときと同じ結果）。
    func setMessagingTimeout(_ timeout: Duration, for element: AXElementRef) throws(AccessibilityReadError) {
        guard timeout > .zero else { throw Self.readError(for: .illegalArgument) }
        try Self.check(AXUIElementSetMessagingTimeout(element.raw, Self.seconds(timeout)))
    }

    /// システム全体のメッセージングのタイムアウトを 50ms にする（design.md 8.5、D-29。起動時に 1 回。T42 が呼ぶ）。
    ///
    /// Tobi のプロセスの中だけに効き、要素ごとの設定をしていない参照すべての既定値になる。
    /// 設定し忘れた参照が既定の約 1.5 秒待つのを防ぐ安全網。
    func applySystemWideMessagingTimeout() throws(AccessibilityReadError) {
        try setMessagingTimeout(Self.systemWideMessagingTimeout, for: .systemWide())
    }

    // MARK: - エラーの変換

    /// `AXError` の結果を確かめる。`.success` なら何もせず、それ以外は `readError(for:)` で変換して投げる。
    static func check(_ result: AXError) throws(AccessibilityReadError) {
        guard result != .success else { return }
        throw readError(for: result)
    }

    /// `AXError` を `AccessibilityReadError` に変換する唯一の場所（design.md 8.7 の表）。
    ///
    /// `.success` を渡すのは呼び出し側の誤り。成功を別の失敗に見せかけないよう、生の値のまま `.other` にする。
    static func readError(for code: AXError) -> AccessibilityReadError {
        switch code {
        case .success:
            .other(code: code.rawValue)
        case .invalidUIElement:
            .invalidElement
        case .cannotComplete:
            .cannotComplete
        case .apiDisabled:
            .apiDisabled
        case .attributeUnsupported, .noValue:
            .attributeUnsupported
        case .actionUnsupported:
            .actionUnsupported
        case .notImplemented:
            .notImplemented
        default:
            .other(code: code.rawValue)
        }
    }

    // MARK: - 内部

    private static func seconds(_ duration: Duration) -> Float {
        let components = duration.components
        return Float(Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    private static func arrayItems(_ array: CFArray) -> [CFTypeRef] {
        let count = CFArrayGetCount(array)
        var items: [CFTypeRef] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            // 一括取得の結果は、失敗した属性の位置にも AXValue が入るので NULL にはならない。
            // 万一 NULL なら kCFNull を置き、位置の対応を崩さない（取り出すと型の不一致になる）
            guard let raw = CFArrayGetValueAtIndex(array, index) else {
                items.append(kCFNull)
                continue
            }
            // 配列が所有している値を借りるだけなので、retain の数は変えない（takeUnretainedValue）
            items.append(Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue())
        }
        return items
    }
}

/// `AXClient.attributeValues(_:of:)` の結果。要求した属性名から値を取り出す。
///
/// CF の値を持つので `Sendable` ではない。読んだスレッドの中で、すぐに型付きの値へ変換して使う。
struct AXAttributeValues {
    private let values: [String: CFTypeRef]

    fileprivate init(values: [String: CFTypeRef]) {
        self.values = values
    }

    /// 変換前の値。要求していない属性なら `.notRequested`。
    func raw(_ attribute: String) throws(AXValueDecodingError) -> CFTypeRef {
        guard let value = values[attribute] else { throw .notRequested(attribute: attribute) }
        return value
    }

    func string(_ attribute: String) throws(AXValueDecodingError) -> String {
        try AXValueDecoder.string(raw(attribute))
    }

    func bool(_ attribute: String) throws(AXValueDecodingError) -> Bool {
        try AXValueDecoder.bool(raw(attribute))
    }

    func point(_ attribute: String) throws(AXValueDecodingError) -> CGPoint {
        try AXValueDecoder.point(raw(attribute))
    }

    func size(_ attribute: String) throws(AXValueDecodingError) -> CGSize {
        try AXValueDecoder.size(raw(attribute))
    }

    func elements(_ attribute: String) throws(AXValueDecodingError) -> [AXElementRef] {
        try AXValueDecoder.elements(raw(attribute))
    }

    func strings(_ attribute: String) throws(AXValueDecodingError) -> [String] {
        try AXValueDecoder.strings(raw(attribute))
    }
}
