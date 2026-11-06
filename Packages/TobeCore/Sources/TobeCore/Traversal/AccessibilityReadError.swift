import Foundation

/// AX の読み取り・操作の失敗。App 側の `AXClient` が `AXError` から変換する（design.md 8.7）。
///
/// TobeCore が ApplicationServices に依存しないよう、`AXError` を直接使わずにここで意味を定義する。
/// `Hashable` なのは、アプリ単位でエラーの種類ごとに件数を数える（辞書のキーにする）ため。
public enum AccessibilityReadError: Error, Hashable, Sendable {
    /// `kAXErrorInvalidUIElement`。要素が消えた。
    case invalidElement
    /// `kAXErrorCannotComplete`。メッセージングのタイムアウトを含む。
    case cannotComplete
    /// `kAXErrorAPIDisabled`。アクセシビリティの権限が取り消された。
    case apiDisabled
    /// `kAXErrorAttributeUnsupported` / `kAXErrorNoValue`。属性なしとして扱う。
    case attributeUnsupported
    /// `kAXErrorActionUnsupported`。
    case actionUnsupported
    /// `kAXErrorNotImplemented`。
    case notImplemented
    /// 上記以外の `AXError`。生の値を残す。
    case other(code: Int32)
}
