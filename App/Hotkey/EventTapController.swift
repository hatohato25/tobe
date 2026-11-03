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
/// - キー破棄が ON の間、keyDown / keyUp は design.md 7.3 の規則（`KeySuppressionTracker`）で破棄し、破棄した keyDown を
///   `.hintKey` で送る（F-7）。flagsChanged とクリックは破棄しない。クリックは `.pointerDown` で送る（暫定 Q-10）。
///   キー破棄の OFF は `setSuppressing(false)`（`KeySuppressionGate`）で行う。
/// - 権限の取り消しと、通知のない無効化・停止への対処は `EventTapWatchdog` が行う（design.md 7.4）。
///
/// スレッド: どのスレッドから呼んでもよい（`Sendable`）。通常は MainActor（`HotkeyModule`）が持つ。
/// `events` の購読者は 1 つにする（`AsyncStream` は複数の購読者に同じ要素を配らない）。
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
        #if DEBUG
            // Debug の --trigger-key（EventTapDebugHooks）。設定の値より優先する（T38 の手動確認のため）
            if let debugTriggerKey = EventTapDebugHooks.options.triggerKey {
                context.updateTriggerKey(debugTriggerKey)
            }
        #endif
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

    /// 起動キーを変える（S-1。T52 の設定画面から呼ぶ）。タップを作り直さずに、次のイベントから新しいキーで判定する。
    /// 押下の途中などの判定の状態は捨てる。
    func updateTriggerKey(_ triggerKey: TriggerKey) {
        context.updateTriggerKey(triggerKey)
    }
}

extension EventTapController: KeySuppressionGate {
    /// キー破棄を切り替える（design.md 7.2・13 章）。MainActor の Coordinator がヒントモードを抜けるときに `false` を渡す。
    ///
    /// ON はタップのスレッドが単独タップの検出時に自分で立てる（D-8）。タップがないときの ON は受け付けない
    /// （作り直したタップが、作った直後からキーを破棄しないようにするため）。待たずに終わる。
    func setSuppressing(_ suppressing: Bool) {
        context.setSuppressing(suppressing)
    }
}

/// `EventTapWatchdog` からの通知。T37 が案内画面の表示と閉じるのに使う（N-3.3〜N-3.5）。
enum EventTapWatchdogEvent: Equatable, Sendable {
    /// 権限が許可された（未許可からの変化）。続けてタップを作り、結果を `.tapStarted` / `.tapStartFailed` で送る。
    case permissionGranted
    /// 権限が取り消された。タップを止め、キー破棄を OFF にした（N-3.4）。
    case permissionRevoked
    /// タップを作った（ウォッチドッグの開始時、許可の後、予期しない停止からの作り直し）。
    case tapStarted
    /// タップを作れなかった（N-3.5）。権限が変わるまで（取り消し → 許可）作り直さない。
    case tapStartFailed(EventTapError)
}

/// 権限とタップの状態を見張り、権限がある間はタップが動いているようにする（design.md 7.4、N-3.4、F-1.10）。
///
/// - 権限の取り消しは `PermissionMonitor.statusChanges()` で知る（`AXIsProcessTrusted()` を 2 か所から呼ばない。
///   T32 の申し送り）。取り消されたらタップを止め、キー破棄を OFF にする（`EventTapController.stop()`）。
///   V-7 で OS はタップを止めないと分かっているため、止めないとヒントモード中ならキー入力が止まったままになる。
/// - 許可されたらタップを作る。
/// - 1 秒ごとに `EventTapController.status` を見る。権限があるのに `.disabled` なら再有効化し（無効化の通知の
///   取りこぼし）、`.notRunning` なら `stop()` → `start()` で作り直す（run loop の予期しない終了）。
///
/// `EventTapController` とは別の型にした。コントローラはタップのスレッドからも触る `Sendable` の型で、
/// こちらは MainActor の `PermissionMonitor` と Timer に依存するため（design.md 13 章）。
///
/// 使い方（T37）: `PermissionMonitor` は App で 1 つだけ作り、`start()` しておく。起動時の権限の案内は
/// `permissionMonitor.status` を見て出す。その後の変化とタップの作成の結果は `events` で受ける。
/// ```swift
/// let watchdog = EventTapWatchdog(controller: eventTap, permissionMonitor: permissionMonitor)
/// Task { for await event in watchdog.events { ... } }
/// watchdog.start()   // 権限があればここでタップを作る
/// ```
/// タップを意図して止めるとき（終了時）は、先に `stop()` を呼ぶ。呼ばないと、1 秒後にタップを作り直す。
@MainActor
final class EventTapWatchdog {
    /// 確認の間隔。V-7 で 5 秒から変えた（取り消しの検出までキー入力が止まったままになり得るため。design.md 7.4）。
    private static let interval: TimeInterval = 1.0

    /// 通知。購読者は 1 つにする。取りこぼさないよう上限なしで溜める（変化は 1 秒に高々数回）。
    let events: AsyncStream<EventTapWatchdogEvent>

    private let continuation: AsyncStream<EventTapWatchdogEvent>.Continuation
    private let controller: EventTapController
    private let permissionMonitor: PermissionMonitor
    private var timer: Timer?
    private var permissionTask: Task<Void, Never>?
    /// 作成中の `controller.start()`。作成中に重ねて作らないために持つ。
    private var startTask: Task<Void, Never>?
    /// 作成に失敗した後は、権限が変わるまで作り直さない。毎秒作り直して失敗の案内を出し続けないため。
    private var isRetryBlockedByFailure = false

    init(controller: EventTapController, permissionMonitor: PermissionMonitor) {
        self.controller = controller
        self.permissionMonitor = permissionMonitor
        (events, continuation) = AsyncStream.makeStream(of: EventTapWatchdogEvent.self, bufferingPolicy: .unbounded)
    }

    isolated deinit {
        timer?.invalidate()
        permissionTask?.cancel()
        continuation.finish()
    }

    /// 見張りを始める。権限があってタップがなければ、ここでタップを作る。すでに始めているときは何もしない。
    func start() {
        guard timer == nil else { return }
        let changes = permissionMonitor.statusChanges()
        permissionTask = Task { [weak self] in
            for await status in changes {
                self?.handlePermissionChange(status)
            }
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            // メインの run loop に登録したタイマーなので、メインスレッドで呼ばれる
            MainActor.assumeIsolated {
                self?.check()
            }
        }
        timer.tolerance = 0.1
        // メニューを開いている間（event tracking モード）も確認を続ける（PermissionMonitor と同じ理由）
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if permissionMonitor.status == .granted {
            startTap(reason: "ウォッチドッグの開始")
        }
    }

    /// 見張りを止める。タップは止めない（止めるときは、この後に `EventTapController.stop()` を呼ぶ）。
    func stop() {
        timer?.invalidate()
        timer = nil
        permissionTask?.cancel()
        permissionTask = nil
    }

    private func handlePermissionChange(_ status: PermissionStatus) {
        isRetryBlockedByFailure = false
        switch status {
        case .notGranted:
            // 作成の途中でも止める（作成中のタップは finishStart で破棄され、start() は stoppedDuringStart で終わる）
            controller.stop()
            Log.hotkey.warning("アクセシビリティ権限が取り消されたため、イベントタップを止め、キー破棄を OFF にした")
            continuation.yield(.permissionRevoked)
        case .granted:
            continuation.yield(.permissionGranted)
            startTap(reason: "権限が許可された")
        }
    }

    /// 1 秒ごとの確認。
    private func check() {
        // 作成中は status が .starting なので見ない
        guard startTask == nil else { return }
        let tapStatus = controller.status
        switch permissionMonitor.status {
        case .notGranted:
            // 取り消しは handlePermissionChange で止めている。それでもタップが残っていれば止める（N-3.4）
            guard tapStatus != .notRunning else { return }
            controller.stop()
            Log.hotkey.error("権限がないのにイベントタップが残っていたので止めた")
        case .granted:
            switch tapStatus {
            case .enabled, .starting:
                break
            case .disabled:
                // 無効化の通知を取りこぼした。ログは reenableIfDisabled が残す
                controller.reenableIfDisabled()
            case .notRunning:
                guard !isRetryBlockedByFailure else { return }
                Log.hotkey.error("イベントタップが予期せず止まっていたので作り直す")
                controller.stop()
                startTap(reason: "予期しない停止からの作り直し")
            }
        }
    }

    private func startTap(reason: String) {
        guard startTask == nil, controller.status == .notRunning else { return }
        Log.hotkey.notice("イベントタップを作る（\(reason, privacy: .public)）")
        let controller = controller
        startTask = Task { [weak self] in
            let result: Result<Void, EventTapError>
            do throws(EventTapError) {
                try await controller.start()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self?.finishStart(result)
        }
    }

    private func finishStart(_ result: Result<Void, EventTapError>) {
        startTask = nil
        switch result {
        case .success:
            continuation.yield(.tapStarted)
        case .failure(.stoppedDuringStart):
            // 作成中に権限が取り消された。.permissionRevoked は送ってある
            Log.hotkey.notice("イベントタップの作成中に停止したので、作成を取りやめた")
        case .failure(.alreadyStarted):
            // startTap で .notRunning を確かめているので、ウォッチドッグの外で start() が呼ばれた場合だけ起きる
            Log.hotkey.fault("ウォッチドッグの外でイベントタップが開始された。ウォッチドッグからは作らない")
        case .failure(let error):
            isRetryBlockedByFailure = true
            continuation.yield(.tapStartFailed(error))
        }
    }
}
