import AppKit
import TobiCore

/// ヒントのラベルを、画面ごとの `OverlayPanel` に配って表示する（`HintOverlayPresenting` の実装。design.md 9.2・9.3、D-16）。
///
/// - パネルは画面ごとに 1 枚。生成時と `rebuildPanels(for:)` のときにだけ作り、ヒントモードのたびに使い回す（N-1）。
/// - `show` は placements を `screenID` で振り分けて、ラベルのある画面のパネルだけを出す。対応するパネルのない
///   placement（画面の構成が変わった直後の古い `ScreenID` など）は捨てるが、件数を `Log.overlay` に出す。
/// - `update(visibleIDs:)` は全パネルのビューに集合を渡して再描画するだけ（位置と実寸は変えない。F-4）。
/// - `hide` は全パネルを外し、ビューのラベルも消す。何も表示していないときに呼んでもよい。
/// - 描画完了の signpost（`Signposts.rendered()`）は `HintOverlayView.draw` が打つので、ここでは打たない。
///
/// 画面の構成の変化は、自分では購読しない。配線（T48）が `ScreenGeometryProvider.screenChanges()` を受けて
/// `coordinator.screensChanged()` の後に `rebuildPanels(for: provider.currentSnapshots())` を呼ぶ。
/// ヒントモードの終了（`hide`）と作り直しの順序を、配線の側の 1 か所で決められるようにするため。
///
/// 使い方:
/// ```swift
/// let controller = OverlayController(screens: provider.currentSnapshots())
/// controller.show(placements, appearance: appearance)   // HintPlacement.place の結果
/// controller.update(visibleIDs: ids)
/// controller.hide()
/// controller.rebuildPanels(for: provider.currentSnapshots())   // 画面の構成が変わったら
/// ```
///
/// スレッド: MainActor でだけ使う（AppKit のウィンドウ）。`NSScreen` の参照は持たない。
@MainActor
final class OverlayController: HintOverlayPresenting {
    /// 画面ごとのパネル。キーは作った時点の `ScreenID`（`NSScreen.screens` の添字）。
    private var panels: [ScreenID: OverlayPanel] = [:]
    /// `show` から `hide` までの間 true。作り直しのときに、表示中だったかをログに出すためだけに使う。
    private var isShowing = false

    /// `screens` の画面ごとにパネルを作る（まだ画面には出さない）。`screens` が空ならパネルは 0 枚。
    init(screens: [ScreenSnapshot]) {
        panels = Self.makePanels(for: screens)
    }

    /// 画面の構成が変わったときに、パネルをすべて作り直す。
    ///
    /// 表示中だった場合は、古いパネルを外したうえで作り直し、新しいパネルには何も出さない（いったん隠す）。
    /// 古い placements の `ScreenID` は新しい構成の添字と対応しないため、出し直すことはしない。
    /// ヒントモードは `screensChanged` で終了する（暫定 Q-10）ので、出し直す必要もない。
    func rebuildPanels(for screens: [ScreenSnapshot]) {
        if isShowing {
            Log.overlay.notice("表示中に画面の構成が変わったため、ラベルを隠してパネルを作り直す")
        }
        for panel in panels.values {
            panel.dismiss()
            panel.hintView.clear()
            panel.close()
        }
        isShowing = false
        panels = Self.makePanels(for: screens)
        Log.overlay.notice("オーバーレイのパネルを作り直した（\(self.panels.count, privacy: .public) 枚）")
    }

    func show(_ placements: [HintPlacement], appearance: LabelAppearance) {
        let byScreen = Dictionary(grouping: placements, by: \.screenID)
        let orphans = byScreen.filter { panels[$0.key] == nil }
        if !orphans.isEmpty {
            let count = orphans.values.reduce(0) { $0 + $1.count }
            let screenIDs = orphans.keys.map(\.rawValue).sorted().map(String.init).joined(separator: ",")
            Log.overlay.error(
                """
                対応するパネルのない画面のラベルを表示しない: \(count, privacy: .public) 個 \
                screenID=[\(screenIDs, privacy: .public)] パネル \(self.panels.count, privacy: .public) 枚
                """
            )
        }
        for (screenID, panel) in panels {
            guard let onThisScreen = byScreen[screenID] else {
                // 前回のセッションでこの画面に出していたラベルを残さない
                panel.dismiss()
                panel.hintView.clear()
                continue
            }
            // present() は先に描画を済ませてから出すので、show を先に呼ぶ（T44）
            panel.hintView.show(onThisScreen, appearance: appearance)
            panel.present()
        }
        isShowing = true
    }

    func update(visibleIDs: Set<ElementID>) {
        // 他の画面の ID が混ざっていても、各ビューは自分のラベルの ID だけを見るので、そのまま全ビューに渡す
        for panel in panels.values {
            panel.hintView.update(visibleIDs: visibleIDs)
        }
    }

    func hide() {
        for panel in panels.values {
            panel.dismiss()
            // 次の show で置き換わるが、前のセッションのラベルとキャッシュを持ち越さないように消す
            panel.hintView.clear()
        }
        isShowing = false
    }

    private static func makePanels(for screens: [ScreenSnapshot]) -> [ScreenID: OverlayPanel] {
        if screens.isEmpty {
            Log.overlay.error("画面がないため、オーバーレイのパネルを作らない")
        }
        var panels: [ScreenID: OverlayPanel] = [:]
        for snapshot in screens {
            panels[snapshot.geometry.id] = OverlayPanel(screenFrame: snapshot.screen.frame)
        }
        return panels
    }
}
