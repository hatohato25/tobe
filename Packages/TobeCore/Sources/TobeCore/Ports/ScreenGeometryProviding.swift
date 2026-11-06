import Foundation

/// 接続中の画面の配置を返す口（design.md 3.5、9.1）。App 側の `ScreenGeometryProvider` が実装する。
///
/// `NSScreen` を読むため MainActor から呼ぶ。
@MainActor
public protocol ScreenGeometryProviding {
    /// 現在の画面の一覧。並びは `ScreenID` の添字の順（先頭が主ディスプレイ）。`HintPlacement.screen(for:in:)` は先頭に近い画面を優先する。
    func currentScreens() -> [ScreenGeometry]
}
