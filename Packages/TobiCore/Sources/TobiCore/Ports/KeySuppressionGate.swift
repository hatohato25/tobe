import Foundation

/// キー破棄（F-7）のフラグを外から切り替える口（design.md 3.5、7.3）。App 側の `EventTapController` が実装する。
///
/// フラグの実体はイベントタップ専用スレッドと共有する状態（`TapContext`、`Mutex` で守る）。
/// ON はタップスレッドが単独タップを判定した時点で自分で立てる（D-8）。MainActor の Coordinator は
/// ヒントモードを抜けるときに OFF にする（マシンが出す ON は 2 回目の ON で、害はない。design.md 5.2）。
/// タップスレッドと MainActor の両方から触るため `Sendable` にし、待たずに終わる同期関数にする。
public protocol KeySuppressionGate: Sendable {
    func setSuppressing(_ suppressing: Bool)
}
