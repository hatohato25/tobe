import CoreGraphics

/// ラベルを割り当てる順に要素を並べる（F-3.4、暫定 Q-15）。
public enum ElementSorter {
    /// 要素の左上の点を基準に y の昇順、同じ y なら x の昇順に並べる。どちらも同じなら `ElementID` の昇順にする。
    ///
    /// - 同じ行とみなす許容幅は設けない（暫定 Q-15）。
    /// - 全ディスプレイ共通のグローバル座標（左上原点）でまとめて並べるため、主ディスプレイの上・左にある
    ///   ディスプレイの要素（負の座標）が先に来る。
    /// - 座標が同じ要素の順序を入力の順序に依存させないため、最後に `ElementID` で比べる。
    ///   収集はアプリ単位で並列に行うので、入力の順序は実行ごとに変わりうる。
    public static func sorted(_ elements: [CollectedElement]) -> [CollectedElement] {
        elements.sorted { lhs, rhs in
            let lhsRect = lhs.frame.rect
            let rhsRect = rhs.frame.rect
            if lhsRect.minY != rhsRect.minY { return lhsRect.minY < rhsRect.minY }
            if lhsRect.minX != rhsRect.minX { return lhsRect.minX < rhsRect.minX }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }
}
