import AppKit

/// 1 枚の画面を覆う、ヒントのラベル用の透過パネル（design.md 9.3、D-16・D-18）。
///
/// - 画面ごとに 1 枚作る（D-16）。作る・作り直す・画面に配るのは `OverlayController`（T45）の責務で、
///   この型は 1 枚のパネルと、その中の `HintOverlayView` を 1 つ作るだけ。
/// - frame には `NSScreen.frame`（AppKit の座標）をそのまま渡す（design.md 9.1）。`NSScreen` の参照は持たない
///   （画面の構成が変わったら `ScreenGeometryProvider.currentSnapshots()` から作り直す）。
/// - 表示・非表示は `present()` / `dismiss()`。どちらも Tobe をアクティブにせず、フォーカスを奪わない（F-3.7）。
///
/// 使い方:
/// ```swift
/// let panel = OverlayPanel(screenFrame: snapshot.screen.frame)
/// panel.hintView.show(placementsOnThisScreen, appearance: appearance)
/// panel.present()
/// panel.hintView.update(visibleIDs: ids, typedCount: n)   // 絞り込み
/// panel.dismiss()
/// ```
///
/// スレッド: MainActor でだけ使う（AppKit のウィンドウ）。
@MainActor
final class OverlayPanel: NSPanel {
    /// このパネルの唯一のビュー（`contentView`）。ラベルの表示・絞り込み・消去はこのビューに対して行う。
    let hintView: HintOverlayView

    /// `screenFrame` は `NSScreen.frame`（AppKit の座標、左下原点）。
    init(screenFrame: NSRect) {
        hintView = HintOverlayView(frame: NSRect(origin: .zero, size: screenFrame.size))
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // D-18: 開いているメニュー（.popUpMenu）・メニューバー・Dock より上に出すため .screenSaver
        level = .screenSaver
        // どの Space にも、フルスクリーンのアプリの上にも出す。Mission Control や ⌘` の対象にしない
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // クリックを下のウィンドウに通す
        ignoresMouseEvents = true
        // 起動時に作って使い回すので、非アクティブ化で隠れたり、閉じて解放されたりしないようにする
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // 表示を速くする（N-1）
        animationBehavior = .none
        contentView = hintView
        // contentRect はウィンドウの初期化の中で constrainFrameRect を通らないことがあるため、明示的に合わせ直す
        setFrame(screenFrame, display: false)
    }

    // キー入力はイベントタップで受ける設計なので、パネルはキー・メインにならない（フォーカスを奪わない）
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // 既定の実装は、ウィンドウをメニューバーの下（visibleFrame）へ押し込む。メニューバーの項目とその上の
    // ラベルを出すため、渡された frame（NSScreen.frame）をそのまま返して画面全体に固定する（T7、V-8）
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Tobe をアクティブにせずに最前面へ出す。
    ///
    /// 先に描画を済ませてから出す。出した瞬間に、前回のセッションの絵や空の絵が一瞬見えるのを避けるため。
    func present() {
        displayIfNeeded()
        orderFrontRegardless()
    }

    /// 画面から外す。パネルとビューのキャッシュは残す（次の `show` で置き換わる）。
    func dismiss() {
        orderOut(nil)
    }
}
