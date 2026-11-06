import CoreGraphics

extension HintPlacement {
    /// ヒントごとに表示する画面と位置を決める（design.md 9.2）。
    ///
    /// 画面は `screen(for:in:)` で選び、`anchor` には要素の左上をその画面のローカル座標に
    /// 変換した値を入れる（暫定 Q-16）。はみ出しの補正（`clamp`）はラベルの実寸が分かる App 側で行う。
    /// 結果は `hints` と同じ順序・同じ件数。`screens` が空のときだけ空を返す（表示する画面がない）。
    public static func place(_ hints: [Hint], screens: [ScreenGeometry]) -> [HintPlacement] {
        hints.compactMap { hint in
            // screens が空でなければ screen(for:in:) は必ず画面を返すので、nil になるのは screens が空のときだけ
            guard let screen = screen(for: hint.element.frame, in: screens) else { return nil }
            return HintPlacement(
                elementID: hint.element.id,
                label: hint.label,
                screenID: screen.id,
                anchor: CoordinateConverter.localPoint(hint.element.frame.rect.origin, in: screen)
            )
        }
    }
}
