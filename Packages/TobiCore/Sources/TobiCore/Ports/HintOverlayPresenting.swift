import Foundation

/// ラベルのオーバーレイを表示する口（design.md 3.5、9 章）。App 側の `OverlayController` が実装する。
///
/// `NSPanel` を操作するため MainActor から呼ぶ。
@MainActor
public protocol HintOverlayPresenting {
    /// ラベルを表示する。`placements` の `anchor` は画面ローカル座標で、画面内に収める補正（`HintPlacement.clamp`）は
    /// ラベルの実寸が分かる実装側で行う。`appearance` はセッション中は変えない（S-0.4）。
    func show(_ placements: [HintPlacement], appearance: LabelAppearance)
    /// 絞り込みの結果を反映する（F-4）。`visibleIDs` に含まれないラベルを隠す。表示中のラベルの位置は変えない。
    func update(visibleIDs: Set<ElementID>)
    /// すべてのラベルを隠す。何も表示していないときに呼んでもよい。
    func hide()
}
