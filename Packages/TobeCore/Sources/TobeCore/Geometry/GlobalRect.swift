import CoreGraphics

/// グローバル座標の矩形。原点は主ディスプレイの左上で、y は下向き（AX / CGWindowList / CGEvent と同じ）。
///
/// AppKit の左下原点の矩形と取り違えないよう、`CGRect` を包んで型で区別する（design.md 9.1、D-15）。
/// AppKit の座標からの変換は `CoordinateConverter` だけが行う。
public struct GlobalRect: Equatable, Sendable {
    public var rect: CGRect

    public init(rect: CGRect) {
        self.rect = rect
    }

    /// 矩形の中心点（グローバル座標）。遮蔽の判定（Q-12）と最寄りの画面の判定に使う。
    public var center: CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}
