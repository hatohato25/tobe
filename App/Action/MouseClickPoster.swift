import CoreGraphics
import TobeCore

/// 代替クリック（design.md 10 章の 4、F-5.2）。要素の中心へ左クリックのマウスイベントを送る。
///
/// `AXPress` が `actionUnsupported` だった要素（テキスト欄、Finder の行など。V-4 で日常的に通ると分かった経路）に使う。
///
/// - 座標: `GlobalRect.center`（左上原点のグローバル座標）を、そのまま `CGEvent` のマウスの位置に使う
///   （`CGEvent` も同じ座標系。AppKit の左下原点への変換は要らない）。
/// - イベントの元: `CGEventSource(stateID: .hidSystemState)`。ハードウェアの入力と同じ状態テーブルを使い、
///   相手のアプリには通常のクリックとして届く。
/// - 送信先: `.cghidEventTap`。Tobe 自身のイベントタップ（`.cgSessionEventTap`）にも届くので、
///   両方のイベントに `TobeEventMarker` を付け、タップ側（T34）が `pointerDown` として扱わないようにする。
/// - カーソルは元の位置に戻さない（暫定 Q-17）。対象アプリのアクティブ化もしない（暫定 Q-18）。
///
/// スレッド: 状態を持たない `Sendable` の値型で、MainActor に隔離しない。`CGEvent` の生成と `post` は
/// どのスレッドから呼んでもよく、ブロックもしない。`AXActionPerformer`（T46）が MainActor の外（GCD のキュー）
/// から同期で呼ぶ想定。
struct MouseClickPoster: Sendable {
    /// `frame` の中心を左クリックする（leftMouseDown → leftMouseUp）。
    ///
    /// - Throws: イベントの元かイベントを作れなかったときは `ActionError.eventCreationFailed`。
    ///   このときは 1 つもイベントを送っていない。
    func clickCenter(of frame: GlobalRect) throws(ActionError) {
        let point = frame.center
        // 2 つとも作れてから送る。down だけ送って up を作れないと、ボタンが押されたままの状態が相手のアプリに残るため
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let mouseDown = Self.makeEvent(.leftMouseDown, at: point, source: source),
            let mouseUp = Self.makeEvent(.leftMouseUp, at: point, source: source)
        else {
            throw .eventCreationFailed
        }
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
    }

    /// 印を付けた左ボタンのマウスイベントを作る。
    private static func makeEvent(_ type: CGEventType, at point: CGPoint, source: CGEventSource) -> CGEvent? {
        guard
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            return nil
        }
        // クリック回数を明示的に 1 にする。AppKit のアプリは clickCount で 1 回のクリックか二重クリックかを決めるため、
        // 生成時の既定値に頼らず「1 回のクリック」と確定させる
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        TobeEventMarker.mark(event)
        return event
    }
}
