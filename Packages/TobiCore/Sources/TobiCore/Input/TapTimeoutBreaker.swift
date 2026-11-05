/// イベントタップの `tapDisabledByTimeout` が短い間に続いたら「異常」と判定する（design.md 7.4）。
///
/// timeout のたびに再有効化するだけだと、異常なタップが復活し続けて全アプリのキーとクリックを遅らせ続ける。
/// 実機では、ヒントモード中に権限を取り消した後、クリックがどのアプリにも届かなくなり、電源ボタンで
/// 強制シャットダウンするしかなくなった。そのときの timeout は 01:26:48・01:26:55・01:27:09 と続き、5 分あまりで 19 回
/// 起きていた。根本原因によらず入力を解放するため、回数と時間だけで判定する。
///
/// `tapDisabledByUserInput` は数えない。Secure Input の開始など、正常な動作でも起きるため。
///
/// 純粋な値型で、スレッド間の保護は持たない。App 側の `TapContext` が `Synchronization.Mutex` で守る。
public struct TapTimeoutBreaker: Equatable, Sendable {
    /// `recordTimeout(at:)` の判定。
    public enum Verdict: Equatable, Sendable {
        /// 再有効化してよい。
        case recover
        /// 異常。再有効化せず、タップを破棄する。
        case abandon
    }

    /// 異常と判定する回数（この回数目で判定する）。
    ///
    /// 1 回の timeout は、システムの一時的な高負荷でも起きる（F-1.10 はこれを再有効化で復旧させる）。2 回までは同じ
    /// 一時的な高負荷の続きとして許す。3 回続けば一時的とは見なさず、入力の解放を優先する。誤判定しても、
    /// 起動キーが効かなくなって再起動を求めるだけで、入力が止まるより害が小さい。
    public static let abandonThreshold = 3

    /// 数える窓の長さ（秒）。
    ///
    /// 実機の不具合では最初の 3 回が 21 秒に収まり、以後も平均して約 16 秒ごとに起きていた。これを確実に捕まえ、
    /// かつ数分に 1 回の一時的な timeout は別々の出来事として数えない長さにする。
    public static let windowSeconds: UInt64 = 30

    private static let windowNanoseconds = windowSeconds * 1_000_000_000

    /// 窓の中の timeout の時刻。古い順。
    private var recentTimeouts: [Timestamp] = []

    public init() {}

    /// timeout を記録し、異常かどうかを返す。
    ///
    /// ちょうど `windowSeconds` 前の記録は窓の中として数える（「30 秒以内」）。
    ///
    /// 時刻が前回より戻っていたら、前回と同じ時刻として数える。`Timestamp` は単調時計の値なので通常は起きないが、
    /// 起きたときに記録を捨てると安全策が効かなくなるため、数える側に倒す。
    ///
    /// - Parameter now: timeout の時刻。
    public mutating func recordTimeout(at now: Timestamp) -> Verdict {
        let current = recentTimeouts.last.map { max($0, now) } ?? now
        // current はどの記録より新しいので、引き算は負にならない
        recentTimeouts.removeAll { current.nanoseconds - $0.nanoseconds > Self.windowNanoseconds }
        recentTimeouts.append(current)
        return recentTimeouts.count >= Self.abandonThreshold ? .abandon : .recover
    }

    /// 記録を捨てて、数え直す。
    public mutating func reset() {
        recentTimeouts.removeAll()
    }
}
