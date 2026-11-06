import CoreGraphics

/// 1 つのヒントを、どの画面のどこに表示するか。
///
/// 画面への割り当ては `screen(for:in:)`、はみ出しの補正は `clamp(origin:labelSize:screenSize:)` で行う。
/// `Hint` を受け取って配置をまとめて作る `place` は `HintPlacement+Hint.swift` にある（T24）。
public struct HintPlacement: Equatable, Sendable {
    public let elementID: ElementID
    public let label: String
    public let screenID: ScreenID
    /// 画面ローカル座標（画面の左上原点、y 下向き）。暫定: 要素の左上（Q-16）。
    /// ラベルの実寸は App 側でしか分からないため、画面内に収める補正（`clamp`）は描画時に行う。
    public let anchor: CGPoint

    public init(elementID: ElementID, label: String, screenID: ScreenID, anchor: CGPoint) {
        self.elementID = elementID
        self.label = label
        self.screenID = screenID
        self.anchor = anchor
    }

    /// ラベルが画面の外にはみ出さないよう、左上の位置を画面内にずらす（F-3.5）。
    ///
    /// すべて画面ローカル座標（左上原点）。ラベルが画面より大きい辺では、左端・上端に揃える
    /// （ラベルの先頭の文字が読めるほうを優先する）。
    public static func clamp(origin: CGPoint, labelSize: CGSize, screenSize: CGSize) -> CGPoint {
        CGPoint(
            x: clamped(origin.x, length: labelSize.width, limit: screenSize.width),
            y: clamped(origin.y, length: labelSize.height, limit: screenSize.height)
        )
    }

    /// 要素を表示する画面を選ぶ（design.md 9.2）。
    ///
    /// 1. 要素の左上の点を含む画面（複数あれば `screens` の先頭に近いもの）
    /// 2. どの画面にも含まれなければ、要素の中心点からの距離（画面の矩形までの最短距離）が最も小さい画面。
    ///    同じ距離なら `screens` の先頭に近いもの
    ///
    /// 画面の判定は `CGRect.contains`（右端・下端を含まない）なので、隣り合う画面の境界上の点は
    /// 右側・下側の画面に入る。`screens` が空のときだけ `nil` を返す。
    public static func screen(for frame: GlobalRect, in screens: [ScreenGeometry]) -> ScreenGeometry? {
        if let containing = screens.first(where: { $0.frame.rect.contains(frame.rect.origin) }) {
            return containing
        }
        let center = frame.center
        // `min(by:)` は同じ値のとき先に現れた要素を返すので、同じ距離なら先頭に近い画面になる
        return screens.min { lhs, rhs in
            squaredDistance(from: center, to: lhs.frame.rect) < squaredDistance(from: center, to: rhs.frame.rect)
        }
    }

    private static func clamped(_ value: Double, length: Double, limit: Double) -> Double {
        max(0, min(value, limit - length))
    }

    /// 点から矩形（の内部を含む）までの最短距離の 2 乗。点が矩形の中にあれば 0。
    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> Double {
        let deltaX = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let deltaY = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return deltaX * deltaX + deltaY * deltaY
    }
}
