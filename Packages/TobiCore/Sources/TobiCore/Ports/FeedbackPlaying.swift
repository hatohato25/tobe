import Foundation

/// 失敗をユーザーに知らせる口（design.md 3.5）。App 側の `SystemFeedback` が実装する（暫定: `NSSound.beep()`）。
///
/// `NSSound` を使うため MainActor から呼ぶ。
@MainActor
public protocol FeedbackPlaying {
    /// 要素が 0 件（Q-11）、収集の失敗、操作の失敗（Q-19）のときに鳴らす。
    func playFailure()
}
