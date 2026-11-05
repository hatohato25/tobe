import CoreGraphics
import Foundation
import Synchronization
import TobiCore

/// タップの CF オブジェクト（design.md 4 章・13 章、D-23）。
///
/// `CFMachPort` と `CFRunLoop` は Swift 6 では `Sendable` ではないが、参照自体は不変で、ここで使う API
/// （`CFMachPortInvalidate`、`CFRunLoopStop`、`CGEvent.tapEnable` / `tapIsEnabled`）は他のスレッドから呼んでよい。
/// また `CFRunLoopGetCurrent()` の戻り値はリージョン解析で「現在の文脈のもの」と見なされ、そのままでは
/// `Mutex` の状態に入れられない。そのため `@unchecked Sendable` で包み、触るのは `TapContext` のロックの中だけにする。
struct TapPortBox: @unchecked Sendable {
    let port: CFMachPort
    /// タップのスレッドの run loop。`stop()` で他のスレッドから止めるために持つ。
    let runLoop: CFRunLoop
}

/// タップの寿命。`generation` は `start()` ごとに変わり、止めた後に古いスレッドが状態を書き換えないようにする。
private enum TapLifecycle {
    case idle
    case starting(generation: UInt64)
    case running(generation: UInt64, resources: TapPortBox)
    /// timeout が続いたので破棄した（`TapTimeoutBreaker`）。終端の状態で、プロセスが終わるまでタップを作らない。
    /// `stop()` でも `.idle` に戻さない。戻すと、ウォッチドッグが異常なタップを作り直せてしまうため。
    case abandoned

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

/// `TapContext` の `Mutex` で守る状態（design.md 7.1）。
private struct TapSharedState {
    var lifecycle: TapLifecycle = .idle
    var lastGeneration: UInt64 = 0
    var detector: ModifierTapDetector
    /// keyDown / keyUp を渡すか破棄するかの判定と、破棄した keyDown の記録（design.md 7.3）。
    /// タップの再有効化や作り直しでは捨てない。破棄した keyDown の keyUp を引き続き破棄するため（design.md 7.4）。
    var tracker = KeySuppressionTracker()
    /// キー破棄（F-7）が ON か。ON はタップのスレッドが単独タップの検出時に立てる（D-8）。
    /// OFF は MainActor（`setSuppressing(false)`）と `stop()`。
    var isSuppressing = false
    /// timeout の連続の判定。タップを作り直しても捨てない。権限の値が揺れてタップの作り直しが繰り返されたときに、
    /// 数え直しで安全策が効かなくならないようにするため。誤判定しても再起動を求めるだけで済む。
    var timeoutBreaker = TapTimeoutBreaker()

    /// タップを破棄し、キー破棄を OFF にする。`lifecycle` が `.running` なら次の状態を `next` にする。
    /// 破棄した keyDown の記録（`tracker`）は捨てない（対応する keyUp を引き続き破棄するため）。
    mutating func releaseTap(whenRunningBecoming next: TapLifecycle) {
        // タップがなくなった後に ON が残ると、次に作ったタップがいきなりキーを破棄するため（N-3.4）
        isSuppressing = false
        detector.reset()
        guard case .running(_, let resources) = lifecycle else { return }
        // 無効にしたポートの source は run loop から外れる。CFRunLoopStop で CFRunLoopRunInMode から戻す
        CFMachPortInvalidate(resources.port)
        CFRunLoopStop(resources.runLoop)
        lifecycle = next
    }
}

/// OS の無効化の通知を受けた結果（ログと通知のため）。
private enum SystemDisableOutcome {
    case reenabled
    /// timeout が続いたので、再有効化せずに破棄した。
    case abandoned
    /// `stop()` の後（破棄の途中）か、すでに破棄した後に届いた。
    case tapNotRunning
}

/// `TapContext.setSuppressing(_:)` の結果（ログのため）。
private enum SuppressionChange {
    case changed
    case unchanged
    /// タップがないので ON を受け付けなかった。
    case rejectedWithoutTap
}

/// タップのコールバックに渡す文脈。タップのスレッドと MainActor の両方から触る状態を `Mutex` で守る。
///
/// コールバックへは `Unmanaged.passUnretained` で渡す。寿命は `EventTapController` が持ち、
/// タップのスレッドも run loop が終わるまで強参照を持つ（`EventTapThread`）。
///
/// `Mutex` は `Sendable` なので、この型は `@unchecked` なしで `Sendable` にできる。
/// ロックの中ではイベントの判定と CF の軽い呼び出しだけを行い、ログと通知はロックの外で行う。
final class TapContext: Sendable {
    private let state: Mutex<TapSharedState>
    private let continuation: AsyncStream<TapEvent>.Continuation
    #if DEBUG
        /// Debug の起動引数 `--tap-hook`（`EventTapDebugHooks`）。起動時に 1 回だけ読む。
        private let debugTapHook: EventTapDebugHooks.TapHook?
    #endif

    init(triggerKey: TriggerKey, continuation: AsyncStream<TapEvent>.Continuation) {
        state = Mutex(TapSharedState(detector: ModifierTapDetector(triggerKey: triggerKey)))
        self.continuation = continuation
        #if DEBUG
            debugTapHook = EventTapDebugHooks.options.tapHook
        #endif
    }

    // MARK: - 寿命（EventTapController / EventTapThread から呼ぶ）

    /// 開始の準備をする。
    /// - Returns: 新しい世代。既に開始している（開始の途中を含む）か、異常で破棄した後なら失敗。
    func beginStart() -> Result<UInt64, EventTapError> {
        state.withLock { shared in
            switch shared.lifecycle {
            case .idle:
                shared.lastGeneration &+= 1
                shared.lifecycle = .starting(generation: shared.lastGeneration)
                return .success(shared.lastGeneration)
            case .starting, .running:
                return .failure(.alreadyStarted)
            case .abandoned:
                return .failure(.abandoned)
            }
        }
    }

    /// タップのスレッドがタップを run loop に載せた後に呼ぶ。
    /// - Returns: 載せたタップを使ってよいなら `true`。作成の途中で `stop()` が呼ばれていたら `false`
    ///   （呼び出し側がタップを破棄する）。
    func finishStart(generation: UInt64, resources: TapPortBox) -> Bool {
        state.withLock { shared in
            guard case .starting(let current) = shared.lifecycle, current == generation else { return false }
            shared.lifecycle = .running(generation: generation, resources: resources)
            // 開始の前の判定の途中状態は持ち込まない
            shared.detector.reset()
            return true
        }
    }

    /// タップの作成に失敗したときに、タップのスレッドが呼ぶ。開始の途中の状態を取り消す。
    func abandonStart(generation: UInt64) {
        state.withLock { shared in
            guard case .starting(let current) = shared.lifecycle, current == generation else { return }
            shared.lifecycle = .idle
        }
    }

    /// タップのスレッドの run loop を回し続けてよいか（その世代のタップがまだ使われているか）。
    func isRunning(generation: UInt64) -> Bool {
        state.withLock { shared in
            guard case .running(let current, _) = shared.lifecycle else { return false }
            return current == generation
        }
    }

    /// タップのスレッドの run loop が終わったときに呼ぶ。
    /// - Returns: `stop()` を経ずに終わった（OS がポートを無効にしたなど）なら `true`。このとき状態を片付ける。
    func endRunning(generation: UInt64) -> Bool {
        state.withLock { shared in
            guard case .running(let current, let resources) = shared.lifecycle, current == generation else {
                return false
            }
            CFMachPortInvalidate(resources.port)
            shared.lifecycle = .idle
            shared.isSuppressing = false
            shared.detector.reset()
            return true
        }
    }

    /// タップを破棄し、キー破棄を OFF にする（`EventTapController.stop()`）。
    func stop() {
        state.withLock { shared in
            shared.releaseTap(whenRunningBecoming: .idle)
            if case .starting = shared.lifecycle {
                // タップのスレッドが finishStart で気付き、作ったタップを破棄する
                shared.lifecycle = .idle
            }
        }
    }

    var status: EventTapStatus {
        state.withLock { shared in
            switch shared.lifecycle {
            case .idle: .notRunning
            case .starting: .starting
            case .running(_, let resources): CGEvent.tapIsEnabled(tap: resources.port) ? .enabled : .disabled
            case .abandoned: .abandoned
            }
        }
    }

    /// タップが無効になっていれば再有効化する（ウォッチドッグ用。design.md 7.4）。
    func reenableIfDisabled() -> Bool {
        let reenabled = state.withLock { shared in
            guard case .running(_, let resources) = shared.lifecycle,
                !CGEvent.tapIsEnabled(tap: resources.port)
            else { return false }
            CGEvent.tapEnable(tap: resources.port, enable: true)
            // 無効の間のイベントは届いていないので、押下中などの途中状態は当てにならない
            shared.detector.reset()
            return true
        }
        if reenabled {
            Log.hotkey.warning("無効になっていたイベントタップを再有効化した（無効化の通知なし）")
        }
        return reenabled
    }

    func finishEvents() {
        continuation.finish()
    }

    // MARK: - MainActor から呼ぶ操作（design.md 13 章）

    /// キー破棄を切り替える（`KeySuppressionGate`）。
    ///
    /// OFF は Coordinator がヒントモードを抜けるときに呼ぶ。ON は通常、タップのスレッドが単独タップの検出時に
    /// 自分で立てている（D-8）ので、ここでの ON は 2 回目の ON になる（design.md 5.2）。
    /// タップが動いていない（作成中を含む）ときの ON は受け付けない。ON のまま次のタップを作ると、作った直後からキーを破棄して
    /// キーボードが効かなくなるため（N-3.4。`stop()` が OFF にするのと同じ理由）。
    func setSuppressing(_ suppressing: Bool) {
        let change: SuppressionChange = state.withLock { shared in
            if suppressing, !shared.lifecycle.isRunning {
                return .rejectedWithoutTap
            }
            guard shared.isSuppressing != suppressing else { return .unchanged }
            shared.isSuppressing = suppressing
            return .changed
        }
        switch change {
        case .changed:
            Log.hotkey.info("キー破棄を \(suppressing ? "ON" : "OFF", privacy: .public) にした")
        case .unchanged:
            break
        case .rejectedWithoutTap:
            Log.hotkey.notice("イベントタップがないため、キー破棄の ON を受け付けなかった")
        }
    }

    /// 起動キーを変える（S-1。設定の変更、Debug の `--trigger-key`）。
    /// `ModifierTapDetector.triggerKey` の `didSet` が判定の途中状態を捨てる（T19）。
    func updateTriggerKey(_ triggerKey: TriggerKey) {
        let previous = state.withLock { shared in
            let previous = shared.detector.triggerKey
            shared.detector.triggerKey = triggerKey
            return previous
        }
        guard previous != triggerKey else { return }
        Log.hotkey.notice(
            "起動キーを変更した: \(previous.rawValue, privacy: .public) → \(triggerKey.rawValue, privacy: .public)"
        )
    }

    // MARK: - コールバック（タップのスレッド）

    /// コールバックの本体。重い処理はせず、判定はロックの中で短く済ませる（design.md 7.2）。
    /// - Returns: イベントを渡すか破棄するか。
    func handle(type: CGEventType, event: CGEvent) -> KeySuppressionTracker.Disposition {
        // 時刻は CGEvent.timestamp ではなく単調時計から取る（D-6）
        let now = Timestamp(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        switch type {
        case .tapDisabledByTimeout:
            handleSystemDisable(reason: .timeout, at: now)
            return .pass
        case .tapDisabledByUserInput:
            handleSystemDisable(reason: .userInput, at: now)
            return .pass
        case .flagsChanged:
            handleFlagsChanged(event: event, at: now)
            // 修飾キーの変化は破棄しない（F-7.3）。起動キーの押下・解放もアプリに届く（spec 4.4）
            return .pass
        case .keyDown:
            return handleKeyDown(event: event, at: now)
        case .keyUp:
            let keyCode = Self.keyCode(of: event)
            // isSuppressing は判定に使われない（ヒントモードの終了後に届いた keyUp も、破棄した keyDown のものなら破棄する）
            return state.withLock { shared in
                shared.tracker.disposition(for: .keyUp, keyCode: keyCode, isSuppressing: shared.isSuppressing)
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handlePointerDown(event: event, at: now)
            // クリックは破棄しない（暫定 Q-10: クリックでヒントモードを抜け、クリック自体はアプリに届ける）
            return .pass
        default:
            return .pass
        }
    }

    private static func keyCode(of event: CGEvent) -> UInt16 {
        UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    }

    /// keyDown を design.md 7.3 の規則で渡すか破棄するかを決め、破棄したら `.hintKey` を送る（F-4、F-7）。
    /// 文字への変換はしない。MainActor の `KeyTranslator` が行う（design.md 7.6、T35）。
    private func handleKeyDown(event: CGEvent, at now: Timestamp) -> KeySuppressionTracker.Disposition {
        let keyCode = Self.keyCode(of: event)
        let disposition = state.withLock { shared in
            // 起動キーの押下中の keyDown（⌘C など）で単独タップの候補から外す（F-1.3）
            _ = shared.detector.handle(.keyDown(at: now))
            return shared.tracker.disposition(for: .keyDown, keyCode: keyCode, isSuppressing: shared.isSuppressing)
        }
        guard disposition == .suppress else { return .pass }
        let flags = ModifierFlags(rawValue: event.flags.rawValue)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // キーの内容（keyCode）はログに出さない（ユーザーの入力のため。design.md 14 章）
        continuation.yield(.hintKey(keyCode: keyCode, flags: flags, isRepeat: isRepeat))
        return .suppress
    }

    /// マウスボタンの押下。起動キーの判定を取り消し（暫定 Q-2: ⌘ クリックで起動しない）、
    /// キー破棄が ON なら `.pointerDown` を送る（暫定 Q-10）。
    private func handlePointerDown(event: CGEvent, at now: Timestamp) {
        // Tobi 自身の代替クリック（MouseClickPoster）は、ユーザーのクリックとして扱わない（design.md 10 章）
        guard !TobiEventMarker.isMarked(event) else { return }
        let isSuppressing = state.withLock { shared in
            _ = shared.detector.handle(.pointerDown(at: now))
            return shared.isSuppressing
        }
        guard isSuppressing else { return }
        continuation.yield(.pointerDown)
    }

    private func handleFlagsChanged(event: CGEvent, at now: Timestamp) {
        let keyCode = Self.keyCode(of: event)
        let flags = ModifierFlags(rawValue: event.flags.rawValue)
        let triggeredKey: TriggerKey? = state.withLock { shared in
            guard shared.detector.handle(.flagsChanged(keyCode: keyCode, flags: flags, at: now)) == .tapped else {
                return nil
            }
            // MainActor に届くまでの間に打たれたキーがアプリに漏れないよう、ここで自分で ON にする（D-8、F-7.5）
            shared.isSuppressing = true
            return shared.detector.triggerKey
        }
        guard let triggeredKey else { return }
        // yield はタップのスレッドからだけ行うので、ロックの外でも順序は保たれる
        continuation.yield(.triggered(at: now))
        Log.hotkey.notice("triggered: 起動キー（\(triggeredKey.rawValue, privacy: .public)）の単独タップを検出した")
        #if DEBUG
            runDebugTapHook()
        #endif
    }

    /// OS がタップを無効化した。すぐに再有効化し、判定の途中状態を捨てる（design.md 7.4、F-1.10）。
    /// 破棄した keyDown の記録（KeySuppressionTracker）は捨てない（対応する keyUp を引き続き破棄するため）。
    ///
    /// timeout が続いたら再有効化せず、この場でタップを破棄する（`TapTimeoutBreaker`）。入力を解放する安全策なので、
    /// MainActor を待たない。MainActor が詰まっていても入力が届くようにするため。
    private func handleSystemDisable(reason: TapDisableReason, at now: Timestamp) {
        let outcome: SystemDisableOutcome = state.withLock { shared in
            shared.detector.reset()
            // stop() の後（破棄の途中）なら再有効化しない。停止済みのタップの通知は数えない
            guard case .running(_, let resources) = shared.lifecycle else { return .tapNotRunning }
            if reason == .timeout, shared.timeoutBreaker.recordTimeout(at: now) == .abandon {
                shared.releaseTap(whenRunningBecoming: .abandoned)
                return .abandoned
            }
            CGEvent.tapEnable(tap: resources.port, enable: true)
            return .reenabled
        }
        switch outcome {
        case .reenabled:
            continuation.yield(.tapReenabled(reason: reason))
            Log.hotkey.warning("イベントタップが OS に無効化された（\(reason.rawValue, privacy: .public)）。再有効化した")
        case .abandoned:
            continuation.yield(.abandoned)
            Log.hotkey.fault(
                """
                イベントタップが \(TapTimeoutBreaker.windowSeconds, privacy: .public) 秒以内に \
                \(TapTimeoutBreaker.abandonThreshold, privacy: .public) 回 timeout で無効化された。\
                入力を解放するため、再有効化せずに破棄し、キー破棄を OFF にした。Tobi を再起動するまで作らない
                """
            )
        case .tapNotRunning:
            Log.hotkey.info("停止済みのイベントタップに無効化の通知が届いた（\(reason.rawValue, privacy: .public)）。再有効化しない")
        }
    }

    #if DEBUG
        /// Debug の `--tap-hook` を、単独タップの検出の直後に実行する（T38 の F-1.10 の手動確認のため）。
        /// 起動キーのタップを合図にすることで、確認する人が無効化の起きる時点を選べるようにしている。
        private func runDebugTapHook() {
            switch debugTapHook {
            case nil:
                return
            case .timeout:
                Log.hotkey.notice("Debug（--tap-hook=timeout）: コールバックを止めて tapDisabledByTimeout を起こす")
                // ロックの外で止める。ロックを持ったまま止めると、MainActor の setSuppressing / status まで止まるため
                Thread.sleep(forTimeInterval: EventTapDebugHooks.timeoutHookSleep)
            case .disable:
                let disabled = state.withLock { shared in
                    guard case .running(_, let resources) = shared.lifecycle else { return false }
                    // 自分で無効にした場合は無効化の通知が届かない。ウォッチドッグの再有効化（1 秒ごと）を確かめるため
                    CGEvent.tapEnable(tap: resources.port, enable: false)
                    return true
                }
                Log.hotkey.notice(
                    "Debug（--tap-hook=disable）: イベントタップを無効にした（disabled=\(disabled, privacy: .public)）"
                )
            }
        }
    #endif
}
