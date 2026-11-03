import Foundation

/// 画面上のクリック可能な要素を集める口（design.md 3.5、8 章）。App 側の `AXElementCollector` が実装する。
///
/// 呼び出し元は MainActor の `HintModeCoordinator` だが、走査は MainActor の外（GCD のグローバルキュー）で
/// アプリごとに並列に行う（design.md 13 章）。そのため `async` で、どの隔離からも呼べるよう `Sendable` にする。
public protocol ElementCollecting: Sendable {
    /// 要素を集める。
    ///
    /// `deadline` を過ぎたアプリの走査は打ち切り、それまでに集めた要素を返す（打ち切りは
    /// `CollectionResult.diagnostics` に残す。F-2.10、N-1.3）。収集自体を続けられないときだけ投げる。
    /// 呼び出し元の Task がキャンセルされたら、走査を止めて `CollectionError.cancelled` を投げる（F-6.2）。
    func collect(deadline: ContinuousClock.Instant) async throws(CollectionError) -> CollectionResult
}
