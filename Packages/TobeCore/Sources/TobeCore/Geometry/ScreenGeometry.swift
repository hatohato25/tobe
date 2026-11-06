import Foundation

/// 1 枚のディスプレイの位置と大きさ（グローバル座標）。
public struct ScreenGeometry: Equatable, Sendable {
    public let id: ScreenID
    /// `NSScreen.frame` を `CoordinateConverter` でグローバル座標に変換したもの。
    public let frame: GlobalRect

    public init(id: ScreenID, frame: GlobalRect) {
        self.id = id
        self.frame = frame
    }
}
