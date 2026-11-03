import Foundation
import TobiCore

// 関連値のラベル `at` は design.md 7.1 で決めたインターフェース（`.triggered(at:)` と読めるようにする）。
// 3 文字未満を禁じる identifier_name に掛かるため、この型の中だけ外す
// swiftlint:disable identifier_name

/// イベントタップのスレッドから MainActor へ送る通知（design.md 7.1）。
///
/// キーの内容は keyCode・修飾キー・リピートの有無だけを持ち、文字には変換しない。
/// 変換は MainActor の `KeyTranslator` が行う（design.md 7.6、D-7）。
enum TapEvent: Equatable, Sendable {
    /// 起動キーの単独タップを検出した（F-1.1）。この時点でキー破棄はタップのスレッドが ON にしてある（D-8）。
    case triggered(at: Timestamp)
    /// キー破棄が ON の間に破棄した keyDown（F-4、F-7）。T34 が送る。
    case hintKey(keyCode: UInt16, flags: ModifierFlags, isRepeat: Bool)
    /// キー破棄が ON の間のマウスボタンの押下（暫定 Q-10）。T34 が送る。
    case pointerDown
    /// OS に無効化されたタップを再有効化した（F-1.10）。ログ用。
    case tapReenabled(reason: TapDisableReason)
}
// swiftlint:enable identifier_name

/// OS がタップを無効化した理由（`CGEventType.tapDisabledByTimeout` / `.tapDisabledByUserInput`。design.md 7.4）。
enum TapDisableReason: String, Equatable, Sendable {
    /// コールバックが長時間返らなかった。
    case timeout
    /// 特定のユーザー入力（Secure Input の開始など）があった。
    case userInput
}

/// タップの状態（ウォッチドッグとログのため。design.md 7.4）。
enum EventTapStatus: Equatable, Sendable {
    /// タップがない（未開始、`stop()` の後、作成の失敗、run loop の予期しない終了）。
    case notRunning
    /// `start()` を呼び、タップのスレッドが作成している最中。
    case starting
    /// タップがあり、有効。
    case enabled
    /// タップはあるが無効になっている（OS の無効化の通知を取りこぼした場合など）。
    case disabled
}

/// `EventTapController.start()` の失敗。
enum EventTapError: Error, Equatable {
    /// 既に開始している（または開始の途中）。作り直すときは先に `stop()` を呼ぶ。
    case alreadyStarted
    /// `CGEvent.tapCreate` が `nil` を返した。権限がない、またはシステムが作成を拒んだ（N-3.5）。
    /// 原因の切り分けのため、そのときの `AXIsProcessTrusted()` と `CGPreflight…` の値は `hotkey` のログに残す。
    case tapCreationFailed
    /// タップの run loop source を作れなかった。
    case runLoopSourceCreationFailed
    /// タップのスレッドの run loop を取れなかった。
    case runLoopUnavailable
    /// 作成の途中で `stop()` が呼ばれた。作ったタップは破棄済み。
    case stoppedDuringStart
}

/// イベントタップの作成・破棄・再有効化と、起動キーの単独タップの検出（design.md 7.1〜7.4、F-1）。
///
/// - タップは専用のスレッド（`EventTapThread`）の run loop で動かす（D-3）。`.cgSessionEventTap` に
///   `.headInsertEventTap` で能動的（`.defaultTap`）なタップを置く（D-4。V-1 でアクセシビリティだけで作れると確認済み）。
/// - タップのスレッドと MainActor で共有する状態は `TapContext` が `Synchronization.Mutex` で守る（design.md 13 章）。
/// - 起動キーの単独タップを検出すると、タップのスレッドが自分でキー破棄を ON にしてから `.triggered` を送る（D-8）。
/// - OS がタップを無効化したら、コールバックの中で再有効化して判定の途中状態を捨て、`.tapReenabled` を送る（F-1.10）。
///
/// スレッド: どのスレッドから呼んでもよい（`Sendable`）。通常は MainActor（`HotkeyModule`）が持つ。
/// `events` の購読者は 1 つにする（`AsyncStream` は複数の購読者に同じ要素を配らない）。
///
/// T34 が足すもの: keyDown / keyUp のキー破棄、マウス押下、`KeySuppressionGate` への準拠、ウォッチドッグ、
/// `updateTriggerKey(_:)`。
final class EventTapController: Sendable {
    /// タップのスレッドからの通知。`start()` / `stop()` を繰り返しても同じストリームを使い続ける。
    /// コントローラが解放されると終わる。
    let events: AsyncStream<TapEvent>

    private let context: TapContext

    /// - Parameter triggerKey: 起動キー（S-1）。タップはまだ作らない（`start()` で作る）。
    init(triggerKey: TriggerKey) {
        // .unbounded: 通知は小さく、MainActor が詰まっても取りこぼさないことを優先する（キーの順序を保つため）
        let (stream, continuation) = AsyncStream.makeStream(of: TapEvent.self, bufferingPolicy: .unbounded)
        events = stream
        context = TapContext(triggerKey: triggerKey, continuation: continuation)
    }

    deinit {
        // タップが残ると、userInfo の context を持つスレッドが止まらない。キー破棄も OFF にしておく
        context.stop()
        context.finishEvents()
    }

    /// 専用のスレッドでタップを作り、run loop に載せる。作成が終わる（成功か失敗が分かる）まで待つ。
    ///
    /// 権限の確認はしない。呼び出し側（T37）が `PermissionMonitor` で許可を確かめてから呼び、
    /// 失敗したら案内画面（`.tapCreationFailed`）を出す（N-3.5）。
    func start() async throws(EventTapError) {
        guard let generation = context.beginStart() else {
            throw .alreadyStarted
        }
        let result: Result<Void, EventTapError> = await withCheckedContinuation { continuation in
            EventTapThread.start(context: context, generation: generation) { result in
                continuation.resume(returning: result)
            }
        }
        try result.get()
    }

    /// タップを破棄し（`CFMachPortInvalidate`、run loop の停止。スレッドは後片付けをして終わる）、キー破棄を OFF にする。
    ///
    /// 権限が取り消されたとき（ウォッチドッグ、T34）や終了時に呼ぶ。キー破棄が ON のままタップがなくなると
    /// 次に作ったタップがいきなりキーを破棄するので、ここで必ず OFF にする（N-3.4）。
    /// 作り直すときは `stop()` の後に `start()` を呼ぶ（古いスレッドの終了を待たなくてよい）。
    /// タップがなければ何もしない。
    func stop() {
        context.stop()
    }

    /// タップの現在の状態。
    var status: EventTapStatus {
        context.status
    }

    /// タップがあるのに無効になっていれば再有効化し、判定の途中状態を捨てる（design.md 7.4。ウォッチドッグ用）。
    ///
    /// - Returns: 再有効化したら `true`。タップがない、または有効なら `false`。
    @discardableResult
    func reenableIfDisabled() -> Bool {
        context.reenableIfDisabled()
    }
}
