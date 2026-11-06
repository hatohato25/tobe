import Foundation

/// 画面に表示されている 1 枚のウィンドウ（`CGWindowListCopyWindowInfo` の 1 項目）。
public struct WindowInfo: Equatable, Sendable {
    public let id: WindowID
    public let ownerPID: ProcessID
    public let frame: GlobalRect
    /// `kCGWindowLayer`。MVP はレイヤー 0 のウィンドウだけを走査する。
    /// 他のレイヤー（メニューバーなど）も遮蔽の判定には使うため保持する。
    public let layer: Int
    /// 前後関係。0 が最前面で、`CGWindowList` の並び順と同じ。
    public let zIndex: Int

    public init(id: WindowID, ownerPID: ProcessID, frame: GlobalRect, layer: Int, zIndex: Int) {
        self.id = id
        self.ownerPID = ownerPID
        self.frame = frame
        self.layer = layer
        self.zIndex = zIndex
    }
}
