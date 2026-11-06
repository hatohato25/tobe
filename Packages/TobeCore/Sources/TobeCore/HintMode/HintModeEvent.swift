import Foundation

/// `HintModeMachine` に送るイベント（design.md 5.1）。`HintModeCoordinator` が送る。
public enum HintModeEvent: Equatable, Sendable {
    /// 起動キーの単独タップ（F-1）。`alphabet` はこの時点で読んだ設定の文字セット（S-0.4）。
    case triggerTapped(alphabet: HintAlphabet)
    /// `HintModeEffect.startCollection` で始めた収集が終わった。
    case collectionSucceeded(SessionID, CollectionResult)
    /// `HintModeEffect.startCollection` で始めた収集が失敗した。
    case collectionFailed(SessionID, CollectionError)
    /// ヒントモード中の keyDown（`HintKeyInput.classify` の結果）。修飾キー付きの Esc も `.escape` で届く（F-6.6）。
    case key(HintKeyInput)
    /// マウスのボタンが押された（F-6.3、暫定 Q-10）。
    case pointerDown
    /// 画面構成が変わった（F-6.3、暫定 Q-10）。
    case screensChanged
}
