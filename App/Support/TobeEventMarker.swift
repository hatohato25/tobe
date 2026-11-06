import CoreGraphics

/// Tobe 自身が送ったマウスイベント（代替クリック）を見分けるための印（design.md 7.1・10 章）。
///
/// 代替クリック（`MouseClickPoster`）は `leftMouseDown` / `leftMouseUp` を `.cghidEventTap` に送るため、
/// Tobe 自身のイベントタップにも届く。印がないと、それを「ユーザーのクリック」（`pointerDown`）として扱い、
/// 起動キーの判定を取り消したり、ヒントモードを抜けたりしてしまう。
///
/// - 値: `0x546F_6269`（ASCII の `"Tobe"`）。`eventSourceUserData` の既定値 0 や、他のアプリが使いそうな小さい値と重ならない値にした。
/// - 送る側: 作った `CGEvent` に `TobeEventMarker.mark(event)` を呼んでから `post(tap: .cghidEventTap)` する。
/// - 受ける側（イベントタップのコールバック）: マウス押下で `TobeEventMarker.isMarked(event)` が `true` なら、
///   判定にも通知にも使わず、そのまま `event` を返す。
///
/// 値の比較だけなので、イベントタップのスレッドから呼んでよい。
enum TobeEventMarker {
    /// `CGEventField.eventSourceUserData` に入れる値。
    static let value: Int64 = 0x546F_6269

    /// 送る前のイベントに印を付ける。
    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: value)
    }

    /// Tobe が送ったイベントなら `true`。
    static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == value
    }
}
