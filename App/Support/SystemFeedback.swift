import AppKit
import TobiCore

/// 失敗の通知を、システムの警告音で鳴らす（`FeedbackPlaying` の実装。design.md 3.5）。
///
/// 要素が 0 件（Q-11）、収集の失敗、操作の失敗（Q-19）のときに `HintModeController` から呼ばれる。
/// 音はユーザーがシステム設定で選んだ警告音になり、消音の設定にも従う。
@MainActor
final class SystemFeedback: FeedbackPlaying {
    func playFailure() {
        NSSound.beep()
    }
}
