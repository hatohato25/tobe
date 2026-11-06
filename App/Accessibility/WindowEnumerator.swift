import CoreGraphics
import Foundation
import TobeCore

/// 現在の Space に表示されているウィンドウを前面から順に列挙する（design.md 8.1 手順 1〜2、D-9）。
///
/// 最小化したウィンドウ、⌘H で隠したアプリ、別の Space のウィンドウは `.optionOnScreenOnly` により含まれない（F-2.4）。
/// デスクトップのアイコンなどは `.excludeDesktopElements` で除く。
/// 状態を持たないので、どのスレッドから呼んでもよい（nonisolated。design.md 6 章の表）。
struct WindowEnumerator: Sendable {
    /// Tobe 自身のプロセス。そのウィンドウ（オーバーレイなど）は走査の対象からも遮蔽の判定からも除く（F-2.12、T22）。
    private let ownPID: ProcessID

    init() {
        ownPID = ProcessID(rawValue: ProcessInfo.processInfo.processIdentifier)
    }

    /// - Throws: `CollectionError.windowListUnavailable`（`CGWindowListCopyWindowInfo` が nil を返した）。
    ///   空の一覧で続けると「要素が 0 件」と区別できないため、失敗として返す。
    func enumerate() throws(CollectionError) -> WindowListSnapshot {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        else {
            throw .windowListUnavailable
        }
        // CFArray は NSArray と toll-free bridge なので、この変換は失敗しない（項目の型は parser が確かめる）。
        let screens = Self.activeDisplayBounds().map { GlobalRect(rect: $0) }
        return WindowListParser.parse(list as NSArray, ownPID: ownPID, screens: screens)
    }

    /// 有効なディスプレイの範囲（AX と同じグローバル座標）。取れなければ空。
    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}
