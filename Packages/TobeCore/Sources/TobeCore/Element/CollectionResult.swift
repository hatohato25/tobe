import Foundation

/// 要素の収集結果。収集は途中で打ち切られることがあるため、打ち切りや読み取り失敗は `diagnostics` に残す。
public struct CollectionResult: Equatable, Sendable {
    /// 遮蔽の判定に使う全レイヤーのウィンドウ。`zIndex` の昇順（前面から）。
    public let windows: [WindowInfo]
    public let elements: [CollectedElement]
    public let diagnostics: [CollectionDiagnostic]

    public init(windows: [WindowInfo], elements: [CollectedElement], diagnostics: [CollectionDiagnostic]) {
        self.windows = windows
        self.elements = elements
        self.diagnostics = diagnostics
    }
}

/// 収集を続けられたが、結果が欠けている可能性があることを示す記録。Coordinator がログに出す（握りつぶさない）。
public enum CollectionDiagnostic: Equatable, Sendable {
    /// 期限までに走査が終わらなかった。`collected` は打ち切るまでに集めた要素数。
    case deadlineExceeded(ProcessID, collected: Int)
    /// 走査するノード数の上限に達した。
    case nodeBudgetExhausted(ProcessID)
    /// `cannotComplete` が続いたため、そのアプリの走査を打ち切った。
    case unresponsive(ProcessID)
    /// 読み取りに失敗したノードの件数（アプリ単位、エラーの種類ごと）。
    case readFailed(ProcessID, AccessibilityReadError, count: Int)
    /// `CGWindowList` の項目をパースできずにスキップした。
    case windowListEntrySkipped(reason: String)
}

/// 収集自体を続けられない失敗。
public enum CollectionError: Error, Equatable, Sendable {
    /// アクセシビリティの権限がない、または取り消された（`AXError.apiDisabled` を含む）。
    case accessibilityNotTrusted
    /// `CGWindowListCopyWindowInfo` が nil を返した。
    case windowListUnavailable
    case cancelled
}
