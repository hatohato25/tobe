import Foundation

/// 単調増加する時刻（起動からのナノ秒）。
///
/// App 側はイベントタップのコールバック内で `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` の値を入れる（D-6）。
/// 壁時計の時刻は時刻合わせで戻ることがあるため使わない。
public struct Timestamp: Comparable, Sendable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}
