import Foundation
import TobiCore

/// 仮のヒントモード（T37）。T48 で `HintModeCoordinator` の結線に置き換え、このファイルは削除する。
///
/// F-7（キー破棄）と F-1（起動キー）を手動で確かめる（T38）ためだけのもの。要素の収集や表示はしない。
/// - `.triggered`: ログに残し、仮のヒントモードに入る。キー破棄はタップのスレッドがすでに ON にしている（D-8）。
/// - `.hintKey`: `KeyTranslator.hintKeyInput(keyCode:flags:isRepeat:)` の分類結果だけをログに出す。
///   keyCode・修飾キーはログに出さない。文字は `privacy: .private` にする（ユーザーの入力のため。design.md 14 章）。
///   Esc ならキー破棄を OFF にして抜ける。
/// - `.pointerDown`: キー破棄を OFF にして抜ける（暫定 Q-10）。
/// - 入ってから 5 秒たったら、キー破棄を OFF にして抜ける（本実装のタイムアウトの代わり）。
///
/// 仮実装のため、`.triggered` が届く前にタイムアウトで OFF にした直後に新しい単独タップが重なると、
/// そのセッションはキー破棄が OFF のまま始まることがある（本実装は T48 の Coordinator が扱う）。
///
/// スレッド: MainActor でだけ使う（`KeyTranslator` が MainActor のため）。
@MainActor
final class TemporaryHintModeStub {
    /// 仮のヒントモードを自動で抜けるまでの時間。
    private static let timeout: Duration = .seconds(5)

    private enum State {
        case idle
        /// 仮のヒントモード中。タイムアウトのタスクを持つ（抜けるときに取り消す）。
        case active(timeout: Task<Void, Never>)
    }

    /// 仮のヒントモードを抜けた理由（ログ用）。
    private enum ExitReason: String {
        case escape
        case pointerDown
        case timeout
        case stopped
    }

    private let eventTap: EventTapController
    private let tapEvents: AsyncStream<TapEvent>
    private let keyTranslator: KeyTranslator
    private var state: State = .idle
    private var eventsTask: Task<Void, Never>?

    /// - Parameters:
    ///   - eventTap: キー破棄の OFF に使う。
    ///   - tapEvents: `eventTap.events`。購読者は 1 つだけにする（`AsyncStream` は複数の購読者に配らない）。
    ///   - keyTranslator: `.hintKey` の分類に使う。
    init(eventTap: EventTapController, tapEvents: AsyncStream<TapEvent>, keyTranslator: KeyTranslator) {
        self.eventTap = eventTap
        self.tapEvents = tapEvents
        self.keyTranslator = keyTranslator
    }

    /// `tapEvents` の購読を始める。すでに始めているときは何もしない。
    func start() {
        guard eventsTask == nil else { return }
        let events = tapEvents
        eventsTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        Log.hotkey.notice("仮のヒントモード（T37）の購読を始めた")
    }

    /// 購読をやめ、仮のヒントモード中ならキー破棄を OFF にして抜ける。
    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        leave(reason: .stopped)
    }

    private func handle(_ event: TapEvent) {
        switch event {
        case .triggered:
            enter()
        case .hintKey(let keyCode, let flags, let isRepeat):
            handleHintKey(keyTranslator.hintKeyInput(keyCode: keyCode, flags: flags, isRepeat: isRepeat))
        case .pointerDown:
            leave(reason: .pointerDown)
        case .tapReenabled(let reason):
            // 再有効化そのもののログはタップ側（TapContext）が出している
            Log.hotkey.info("仮のヒントモード: タップの再有効化の通知を受けた（\(reason.rawValue, privacy: .public)）")
        }
    }

    private func enter() {
        if case .active(let timeout) = state {
            // 仮のヒントモード中にもう一度単独タップした。タイムアウトを数え直す
            timeout.cancel()
        }
        let timeout = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.timeout)
            } catch {
                // CancellationError: 抜けた・数え直したので何もしない
                return
            }
            self?.leave(reason: .timeout)
        }
        state = .active(timeout: timeout)
        Log.hotkey.notice("仮のヒントモードに入った（triggered を受けた。キー破棄はタップのスレッドが ON にしてある）")
    }

    private func handleHintKey(_ input: HintKeyInput) {
        guard case .active = state else {
            // OFF にした後に届いた、OFF より前に破棄された keyDown。ヒントモード外なので扱わない
            Log.hotkey.info("仮のヒントモード外で hintKey を受けた（扱わない）")
            return
        }
        switch input {
        case .character(let character):
            Log.hotkey.info("仮のヒントモード: hintKey → character(\(String(character), privacy: .private))")
        case .backspace:
            Log.hotkey.info("仮のヒントモード: hintKey → backspace")
        case .escape:
            Log.hotkey.info("仮のヒントモード: hintKey → escape")
            leave(reason: .escape)
        case .ignored(let reason):
            Log.hotkey.info("仮のヒントモード: hintKey → ignored(\(String(describing: reason), privacy: .public))")
        }
    }

    private func leave(reason: ExitReason) {
        // 仮のヒントモード外でも OFF にする。タップのスレッドが ON にした後、`.triggered` がまだ届いていない
        // 場合などに ON のまま残さないため（変化がなければ setSuppressing は何もしない）
        eventTap.setSuppressing(false)
        guard case .active(let timeout) = state else { return }
        timeout.cancel()
        state = .idle
        Log.hotkey.notice("仮のヒントモードを抜けた（\(reason.rawValue, privacy: .public)）。キー破棄を OFF にした")
    }
}
