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
}

/// `TapContext` の `Mutex` で守る状態（design.md 7.1）。
private struct TapSharedState {
    var lifecycle: TapLifecycle = .idle
    var lastGeneration: UInt64 = 0
    var detector: ModifierTapDetector
    /// キー破棄（F-7）が ON か。ON はタップのスレッドが単独タップの検出時に立てる（D-8）。
    /// OFF は MainActor（`KeySuppressionGate`、T34）と `stop()`。
    var isSuppressing = false
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

    init(triggerKey: TriggerKey, continuation: AsyncStream<TapEvent>.Continuation) {
        state = Mutex(TapSharedState(detector: ModifierTapDetector(triggerKey: triggerKey)))
        self.continuation = continuation
    }

    // MARK: - 寿命（EventTapController / EventTapThread から呼ぶ）

    /// 開始の準備をする。
    /// - Returns: 新しい世代。既に開始している（開始の途中を含む）なら `nil`。
    func beginStart() -> UInt64? {
        state.withLock { shared in
            guard case .idle = shared.lifecycle else { return nil }
            shared.lastGeneration &+= 1
            shared.lifecycle = .starting(generation: shared.lastGeneration)
            return shared.lastGeneration
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
            // タップがなくなった後に ON が残ると、次に作ったタップがいきなりキーを破棄するため（N-3.4）
            shared.isSuppressing = false
            shared.detector.reset()
            switch shared.lifecycle {
            case .idle:
                break
            case .starting:
                // タップのスレッドが finishStart で気付き、作ったタップを破棄する
                shared.lifecycle = .idle
            case .running(_, let resources):
                // 無効にしたポートの source は run loop から外れる。CFRunLoopStop で CFRunLoopRunInMode から戻す
                CFMachPortInvalidate(resources.port)
                CFRunLoopStop(resources.runLoop)
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

    // MARK: - コールバック（タップのスレッド）

    /// コールバックの本体。重い処理はせず、判定はロックの中で短く済ませる（design.md 7.2）。
    /// - Returns: イベントを渡すか破棄するか。
    func handle(type: CGEventType, event: CGEvent) -> KeySuppressionTracker.Disposition {
        // 時刻は CGEvent.timestamp ではなく単調時計から取る（D-6）
        let now = Timestamp(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        switch type {
        case .tapDisabledByTimeout:
            reenableAfterSystemDisable(reason: .timeout)
            return .pass
        case .tapDisabledByUserInput:
            reenableAfterSystemDisable(reason: .userInput)
            return .pass
        case .flagsChanged:
            handleFlagsChanged(event: event, at: now)
            // 修飾キーの変化は破棄しない（F-7.3）。起動キーの押下・解放もアプリに届く（spec 4.4）
            return .pass
        case .keyDown:
            // 起動キーの押下中の keyDown（⌘C など）で単独タップの候補から外す（F-1.3）。
            // キー破棄（KeySuppressionTracker）と .hintKey の通知は T34 が足す
            state.withLock { shared in
                _ = shared.detector.handle(.keyDown(at: now))
            }
            return .pass
        case .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // T34 が足す（keyUp の破棄、マウス押下による判定の取り消しと通知。TobiEventMarker の除外を含む）
            return .pass
        default:
            return .pass
        }
    }

    private func handleFlagsChanged(event: CGEvent, at now: Timestamp) {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
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
    }

    /// OS がタップを無効化した。すぐに再有効化し、判定の途中状態を捨てる（design.md 7.4、F-1.10）。
    /// 破棄した keyDown の記録（KeySuppressionTracker）は捨てない（対応する keyUp を引き続き破棄するため）。
    private func reenableAfterSystemDisable(reason: TapDisableReason) {
        let reenabled = state.withLock { shared in
            shared.detector.reset()
            // stop() の後（破棄の途中）なら作り直さない
            guard case .running(_, let resources) = shared.lifecycle else { return false }
            CGEvent.tapEnable(tap: resources.port, enable: true)
            return true
        }
        guard reenabled else {
            Log.hotkey.info("停止済みのイベントタップに無効化の通知が届いた（\(reason.rawValue, privacy: .public)）。再有効化しない")
            return
        }
        continuation.yield(.tapReenabled(reason: reason))
        Log.hotkey.warning("イベントタップが OS に無効化された（\(reason.rawValue, privacy: .public)）。再有効化した")
    }
}
