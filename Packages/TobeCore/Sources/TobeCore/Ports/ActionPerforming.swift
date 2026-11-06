import Foundation

/// ヒントの確定で行う操作。
public enum HintAction: Hashable, Sendable {
    /// 左クリック（F-5）。MVP はこれだけ。F-8〜F-10 で case を足す。
    case leftClick
}

/// 操作に実際に使った方法。ログに残す（F-5.1、F-5.2）。
public enum ActionMethod: Hashable, Sendable {
    /// `AXPress` で操作した（F-5.1）。
    case axPress
    /// `AXPress` が `actionUnsupported` だったため、要素の中心へのマウスクリックで代替した（F-5.2）。
    case mouseClick
}

/// 操作の失敗（design.md 10 章）。
///
/// 代替クリックに切り替えてよいのは `actionUnsupported` のときだけ（`allowsFallbackClick`）。
/// それ以外の AX のエラー（特に `cannotComplete`。タイムアウトでも相手のアプリでは操作が実行されていることがある）
/// で代替クリックを送ると二重に操作するおそれがあるため、切り替えずに失敗として扱う（Q-19、D-19）。
public enum ActionError: Error, Hashable, Sendable {
    /// セッションの対応表に要素がない（古い要素）。
    case elementNotFound(ElementID)
    /// 要素が `AXPress` に対応していない。代替クリックに切り替える。
    ///
    /// `ActionPerforming.perform` の外へ投げるのは、代替クリックを使えないとき（未注入など）だけ。
    case actionUnsupported
    /// `actionUnsupported` 以外の AX のエラー。代替クリックはしない（Q-19）。
    ///
    /// 値が `.actionUnsupported` になることはない。AX のエラーからは `init(pressFailure:)` で作る。
    case accessibility(AccessibilityReadError)
    /// 代替クリックの `CGEvent` を作れなかった。
    case eventCreationFailed

    /// `AXPress` の失敗を `ActionError` に変換する。`actionUnsupported` とそれ以外を分ける唯一の箇所。
    public init(pressFailure error: AccessibilityReadError) {
        switch error {
        case .actionUnsupported:
            self = .actionUnsupported
        case .invalidElement, .cannotComplete, .apiDisabled, .attributeUnsupported, .notImplemented, .other:
            self = .accessibility(error)
        }
    }

    /// この失敗のあとに代替クリック（`ActionMethod.mouseClick`）へ切り替えてよいか。
    public var allowsFallbackClick: Bool {
        switch self {
        case .actionUnsupported:
            true
        case .elementNotFound, .accessibility, .eventCreationFailed:
            false
        }
    }
}

/// 確定した要素を操作する口（design.md 3.5、10 章）。App 側の `AXActionPerformer` が実装する。
///
/// `AXPress` がモーダルダイアログを開くと相手のアプリが応答するまで呼び出しがブロックされるため、
/// 操作は MainActor の外（GCD のキュー）で行う（design.md 13 章）。そのため `async` で `Sendable` にする。
public protocol ActionPerforming: Sendable {
    /// `element` に `action` を行い、実際に使った方法を返す。
    ///
    /// `AXPress` が `actionUnsupported` のときだけ代替クリックを行う。それ以外の失敗では代替せずに投げる。
    func perform(_ action: HintAction, on element: CollectedElement) async throws(ActionError) -> ActionMethod
}
