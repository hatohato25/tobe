import Foundation

/// 入力済みの文字列によるヒントの絞り込み結果（F-4.1、F-4.2）。
public enum LabelMatch: Equatable, Sendable {
    /// 入力がラベルに完全一致した。この要素への操作を要求する。
    case confirmed(Hint)
    /// 入力を接頭辞に持つ候補（1 件以上。`hints` の順序のまま）。これだけを表示する。
    case narrowed([Hint])
    /// 入力を接頭辞に持つラベルがない。呼び出し側は入力を無視する（暫定 Q-6、F-4.4）。
    case noMatch
}

/// 入力済みの文字列でヒントを絞り込む（design.md 6.3）。
public enum LabelFilter {
    /// 完全一致するラベルがあれば `.confirmed`、接頭辞が一致するラベルがあれば `.narrowed`、
    /// どちらもなければ `.noMatch` を返す。大文字と小文字は区別しない（F-4.5）。
    ///
    /// `HintLabelGenerator` のラベル集合では、空でない入力に対して候補が 1 件になるのは
    /// 完全一致したときだけなので、`.narrowed` の候補は常に 2 件以上になる（F-4.3、Q-5）。
    /// 例外は入力が空のときで、ヒントが 1 件なら `.narrowed` の候補は 1 件になる
    /// （入力前の初期状態にあたる）。
    ///
    /// 計算量は O(ヒントの数 × 入力の長さ)。キーを押すたびに呼ぶ。
    public static func match(_ typed: String, in hints: [Hint]) -> LabelMatch {
        let normalized = typed.lowercased()
        // ラベルは互いに接頭辞にならないので、完全一致は高々 1 件。接頭辞の一致より優先する
        if let exact = hints.first(where: { $0.label == normalized }) {
            return .confirmed(exact)
        }
        let candidates = hints.filter { $0.label.hasPrefix(normalized) }
        return candidates.isEmpty ? .noMatch : .narrowed(candidates)
    }
}
