import Foundation

/// ラベルを割り当てた 1 つの要素。
public struct Hint: Equatable, Sendable {
    /// 小文字で保持する。表示するときだけ大文字にする（Q-8）。
    public let label: String
    public let element: CollectedElement

    /// `label` は小文字にそろえて保持する。
    ///
    /// `HintLabelGenerator` のラベルは文字セット（a-z の小文字。D-21）の文字だけでできているので、
    /// 通常はそのままの値になる。入力との比較（`LabelFilter`）を小文字どうしで行うための保証。
    public init(label: String, element: CollectedElement) {
        self.label = label.lowercased()
        self.element = element
    }
}
