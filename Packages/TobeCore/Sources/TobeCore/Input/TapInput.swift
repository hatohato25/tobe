import Foundation

// 関連値のラベル `at` は design.md 3.4 で決めた公開インターフェース（`.keyDown(at:)` と読めるようにする）。
// 3 文字未満を禁じる identifier_name に掛かるため、この型の中だけ外す
// swiftlint:disable identifier_name

/// `ModifierTapDetector` に渡す入力（design.md 3.4、7.2）。
///
/// App 側のイベントタップのコールバックが `CGEvent` から作る。キーの内容（どの文字か）は持たない。
/// 単独タップの判定には「何かが押された」ことだけが要るため（キー入力を必要以上に持ち回らない）。
public enum TapInput: Equatable, Sendable {
    /// 修飾キーの状態の変化。`keyCode` は変化したキー、`flags` は変化した後の状態。
    case flagsChanged(keyCode: UInt16, flags: ModifierFlags, at: Timestamp)
    /// 修飾キー以外のキーの押下（⌘C など。F-1.3）。
    case keyDown(at: Timestamp)
    /// マウスボタンの押下（⌘ クリック。F-1.5、暫定 Q-2）。
    case pointerDown(at: Timestamp)
}
// swiftlint:enable identifier_name

/// `ModifierTapDetector.handle(_:)` の結果。
public enum TapDetection: Equatable, Sendable {
    case none
    /// 起動キーの単独タップを検出した（F-1.1）。
    case tapped
}
