import Foundation

/// `HintModeMachine` が返す副作用の指示（design.md 5.1）。`HintModeCoordinator` が配列の順にポートの呼び出しへ変える。
public enum HintModeEffect: Equatable, Sendable {
    /// キー破棄の ON / OFF（`KeySuppressionGate.setSuppressing(_:)`。F-7）。
    case setKeySuppression(Bool)
    /// 要素の収集を始める（`ElementCollecting.collect(deadline:)`）。結果は同じ `SessionID` で送り返す。
    case startCollection(SessionID)
    /// 収集をやめる。後から届いた結果は `HintModeMachine` が古いものとして捨てる（F-6.2）。
    case cancelCollection(SessionID)
    /// 件数の上限（`HintPipeline.maxHints`）を超えて切り捨てた要素がある。`count` は 1 以上。
    ///
    /// 黙って捨てないためのエフェクトで、Coordinator は `collector` カテゴリのログに件数を出す（design.md 3.6、T25）。
    /// 出すときは必ず `showHints` の直前に出す。
    case reportTruncatedHints(count: Int)
    /// ラベルを表示する（`HintOverlayPresenting.show`）。1 件以上。
    case showHints([Hint])
    /// 絞り込みの結果を反映する（`HintOverlayPresenting.update(visibleIDs:typedCount:)`。F-4）。
    ///
    /// `typed` は反映した後の入力済みの文字列（`SelectionContext.typed`。空もありうる）。表示中のラベルはすべて
    /// `typed` を接頭辞に持つので、オーバーレイは先頭の `typed.count` 文字を入力済みとして薄く描く。
    case updateHints(visible: Set<ElementID>, typed: String)
    /// すべてのラベルを隠す（`HintOverlayPresenting.hide()`）。
    case hideHints
    /// 確定した要素を操作する（`ActionPerforming.perform`。F-5）。
    case perform(HintAction, CollectedElement)
    /// 失敗の音を鳴らす（`FeedbackPlaying.playFailure()`。要素 0 件の Q-11、収集の失敗）。
    case playFailure
}
