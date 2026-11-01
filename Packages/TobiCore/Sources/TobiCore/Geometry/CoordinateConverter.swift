import CoreGraphics

/// グローバル座標（主ディスプレイの左上原点、y 下向き）と AppKit の座標（主ディスプレイの左下原点、y 上向き）の変換。
///
/// 内部はすべてグローバル座標で扱い、AppKit からの変換は `NSScreen.frame` を `ScreenGeometry` にする
/// 1 箇所だけで行う（design.md 9.1、D-15）。単位はポイントで、Retina かどうかで変わらない。
public enum CoordinateConverter {
    /// AppKit（左下原点）→ グローバル（左上原点）。
    ///
    /// - Parameter primaryHeight: 主ディスプレイ（`NSScreen.screens[0]`）の `frame.height`。
    ///   `NSScreen.main` はキーウィンドウのある画面なので使わない。
    public static func globalRect(fromAppKit rect: CGRect, primaryHeight: Double) -> GlobalRect {
        GlobalRect(rect: flipped(rect, primaryHeight: primaryHeight))
    }

    /// グローバル → AppKit。パネルの frame は `NSScreen.frame` をそのまま使うので、主にテストと検証用。
    public static func appKitRect(from rect: GlobalRect, primaryHeight: Double) -> CGRect {
        flipped(rect.rect, primaryHeight: primaryHeight)
    }

    /// グローバル座標の点を、指定した画面のローカル座標（画面の左上原点、y 下向き）に変換する。
    /// オーバーレイのビューは `isFlipped = true` なので、この値をそのまま描画位置に使える。
    public static func localPoint(_ point: CGPoint, in screen: ScreenGeometry) -> CGPoint {
        CGPoint(x: point.x - screen.frame.rect.minX, y: point.y - screen.frame.rect.minY)
    }

    /// `y' = primaryHeight − (y + height)`。x はそのまま。
    /// 原点の位置と y の向きが両方反転するだけなので、同じ式が両方向の変換になる。
    private static func flipped(_ rect: CGRect, primaryHeight: Double) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - (rect.origin.y + rect.size.height),
            width: rect.size.width,
            height: rect.size.height
        )
    }
}
