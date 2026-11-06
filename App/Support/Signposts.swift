import os

/// ヒントモードの性能計測用の signpost（design.md 14 章、N-1）。
///
/// Instruments の os_signpost（subsystem `io.github.hatohato25.tobe`、category `performance`）で見る。
/// - 区間 `hintSession`: 起動キーの判定時刻から、ヒントモードの終了（確定・取り消し・失敗）まで。
/// - イベント `collected`: 収集の完了（`AXElementCollector`）。
/// - イベント `hintsBuilt`: ラベルの割り当ての完了（`HintPipeline.makeHints` の後）。
/// - イベント `rendered`: `HintOverlayView.draw(_:)` の完了。
///
/// ヒントモードは同時に 1 つしか動かないため、区間とイベントは固定の ID（`OSSignpostID.exclusive`）で打つ。
/// こうするとイベントを打つ側（収集器・オーバーレイ）が区間のハンドルを受け取らなくても、Instruments で同じ区間に並ぶ。
///
/// 使い方:
/// ```swift
/// let session = Signposts.beginHintSession()   // 起動キーを判定したとき
/// Signposts.collected(elementCount: result.elements.count)
/// Signposts.hintsBuilt(hintCount: pipelineResult.hints.count)
/// Signposts.rendered()                          // draw(_:) の最後
/// session.end()                                 // ヒントモードを抜けたとき
/// ```
///
/// `OSSignposter` は `Sendable` なので `static let` で持ち、どのスレッドからでも打てる。
/// メッセージには件数だけを入れる（要素の内容は残さない）。
enum Signposts {
    static let signposter = OSSignposter(subsystem: Log.subsystem, category: "performance")

    /// `hintSession` の区間を始める。戻り値の `end()` で閉じる。
    static func beginHintSession() -> HintSessionSignpost {
        HintSessionSignpost(state: signposter.beginInterval("hintSession", id: .exclusive))
    }

    /// 収集の完了。
    static func collected(elementCount: Int) {
        signposter.emitEvent("collected", id: .exclusive, "elements=\(elementCount)")
    }

    /// ラベルの割り当ての完了。
    static func hintsBuilt(hintCount: Int) {
        signposter.emitEvent("hintsBuilt", id: .exclusive, "hints=\(hintCount)")
    }

    /// オーバーレイの描画の完了。
    static func rendered() {
        signposter.emitEvent("rendered", id: .exclusive)
    }
}

/// 開始済みの `hintSession` 区間。`end()` を 1 回だけ呼ぶ。
struct HintSessionSignpost: Sendable {
    fileprivate let state: OSSignpostIntervalState

    func end() {
        Signposts.signposter.endInterval("hintSession", state)
    }
}
