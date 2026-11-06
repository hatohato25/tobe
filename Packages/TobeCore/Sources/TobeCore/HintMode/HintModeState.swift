import Foundation

/// ヒントモードの 1 回分（単独タップから終了まで）を表す識別子（design.md 5.1）。
///
/// `HintModeMachine` が単調に増やして払い出す。Esc などで収集をやめた後に届いた古い収集結果を
/// 見分けて捨てるために使う（F-6.2）。
public struct SessionID: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// ヒントモードの状態（design.md 5.1）。
///
/// 「確定」は状態として持たず、`selecting → idle` の遷移と `HintModeEffect.perform` で表す（D-2）。
public enum HintModeState: Equatable, Sendable {
    /// 待機。キー入力はそのまま対象アプリへ渡る。
    case idle
    /// 要素の収集中（ラベルの表示前）。キーは破棄する（F-7、暫定 Q-4）。
    case collecting(CollectingContext)
    /// ラベルの入力中。キーは破棄する（F-7）。
    case selecting(SelectionContext)
}

/// 収集中の状態が持つ値。
public struct CollectingContext: Equatable, Sendable {
    public let sessionID: SessionID
    /// セッションの開始時に読んだ文字セット。セッション中は変えない（S-0.4）。
    public let alphabet: HintAlphabet
    // 初期化は合成されるメンバーワイズ（internal）を使う。作るのは HintModeMachine だけ
}

/// ラベル入力中の状態が持つ値。
public struct SelectionContext: Equatable, Sendable {
    public let sessionID: SessionID
    /// 表示したすべてのヒント（`HintPipeline` の結果の順序のまま）。1 件以上。
    public let hints: [Hint]
    /// 入力済みの文字列。`HintKeyInput.character` が小文字にそろえた文字だけからなる。
    /// 値を変えるのは `HintModeMachine` だけ（状態は `private(set)` で公開されるため、外から書き換わることはない）。
    public internal(set) var typed: String

    init(sessionID: SessionID, hints: [Hint], typed: String) {
        self.sessionID = sessionID
        self.hints = hints
        self.typed = typed
    }

    /// `typed` を接頭辞に持つヒント。`typed` が空ならすべてのヒント。
    public var visibleHints: [Hint] {
        hints.filter { $0.label.hasPrefix(typed) }
    }
}
