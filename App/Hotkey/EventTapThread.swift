import ApplicationServices
import CoreGraphics
import Foundation

/// イベントタップ専用のスレッド（D-3）。タップを作り、そのスレッドの run loop に載せて回す。
///
/// メインスレッドが描画や設定画面で詰まってもキー入力が遅れず、OS にタイムアウトで無効化されないよう、
/// タップはメインの run loop に載せない。
enum EventTapThread {
    /// 監視するイベント（design.md 7.1）。マウスの押下は暫定 Q-2（⌘ クリックで起動しない）と Q-10 のため。
    private static let eventMask: CGEventMask = [
        CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]
    .reduce(0) { mask, type in mask | (CGEventMask(1) << CGEventMask(type.rawValue)) }

    /// run loop が `stop()` に気付くまでの最大の間隔（秒）。
    /// `CFRunLoopStop` は run loop が回っていないときに呼ばれると効かないため、一定時間ごとに世代を確かめる。
    private static let runLoopCheckInterval: CFTimeInterval = 1.0

    /// スレッドを起動する。作成の結果（成功・失敗）は `completion` で 1 回だけ返す。
    ///
    /// - Parameters:
    ///   - context: コールバックの文脈。スレッドが run loop を回す間、強参照で持つ。
    ///   - generation: `TapContext.beginStart()` が返した世代。
    static func start(
        context: TapContext,
        generation: UInt64,
        completion: @escaping @Sendable (Result<Void, EventTapError>) -> Void
    ) {
        let thread = Thread {
            run(context: context, generation: generation, completion: completion)
        }
        thread.name = "io.github.hatohato25.tobi.EventTapThread"
        // キー入力を遅らせないよう、メインスレッドと同等の優先度で動かす
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// スレッドの本体。タップを作って run loop に載せ、`stop()` されるまで回す。
    private static func run(
        context: TapContext,
        generation: UInt64,
        completion: @Sendable (Result<Void, EventTapError>) -> Void
    ) {
        let installed: InstalledTap
        switch install(context: context, generation: generation) {
        case .success(let tap):
            installed = tap
        case .failure(let error):
            completion(.failure(error))
            return
        }
        Log.hotkey.notice(
            "イベントタップを作成した（.cgSessionEventTap / .defaultTap）。\(permissionDiagnostics(), privacy: .public)"
        )
        completion(.success(()))

        while context.isRunning(generation: generation) {
            let result = CFRunLoopRunInMode(.defaultMode, runLoopCheckInterval, false)
            // .stopped は stop() の CFRunLoopStop、.finished は source がなくなった（ポートの無効化）
            if result == .stopped || result == .finished {
                break
            }
        }

        CFRunLoopRemoveSource(installed.runLoop, installed.source, .commonModes)
        if context.endRunning(generation: generation) {
            // stop() を経ずに終わった。キー破棄は OFF にしてある。作り直すかはウォッチドッグ（T34）が status で判断する
            Log.hotkey.error("イベントタップの run loop が予期せず終了した（ポートが無効になった）")
        } else {
            Log.hotkey.notice("イベントタップを破棄し、タップのスレッドを終了した")
        }
    }

    /// このスレッドに載せたタップ。スレッドの外には出さない（他のスレッドへは `TapPortBox` で渡す）。
    private struct InstalledTap {
        let source: CFRunLoopSource
        let runLoop: CFRunLoop
    }

    /// タップを作り、このスレッドの run loop に載せて `TapContext` に登録する。
    /// 失敗したときは、作りかけのタップを破棄し、開始の途中の状態を取り消してから返す。
    private static func install(context: TapContext, generation: UInt64) -> Result<InstalledTap, EventTapError> {
        // userInfo は passUnretained。context は run(context:) の引数（スレッドのクロージャ）が run loop の終わりまで保持する
        let userInfo = Unmanaged.passUnretained(context).toOpaque()
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: eventTapCallback,
                userInfo: userInfo
            )
        else {
            context.abandonStart(generation: generation)
            logCreationFailure(reason: "CGEvent.tapCreate が nil を返した")
            return .failure(.tapCreationFailed)
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            context.abandonStart(generation: generation)
            logCreationFailure(reason: "CFMachPortCreateRunLoopSource が nil を返した")
            return .failure(.runLoopSourceCreationFailed)
        }
        guard let runLoop = CFRunLoopGetCurrent() else {
            CFMachPortInvalidate(port)
            context.abandonStart(generation: generation)
            logCreationFailure(reason: "CFRunLoopGetCurrent が nil を返した")
            return .failure(.runLoopUnavailable)
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        guard context.finishStart(generation: generation, resources: TapPortBox(port: port, runLoop: runLoop)) else {
            // 作成の途中で stop() が呼ばれた。キーを破棄し得るタップを残さない
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(port)
            Log.hotkey.notice("イベントタップの作成の途中で停止が要求されたので、作ったタップを破棄した")
            return .failure(.stoppedDuringStart)
        }
        return .success(InstalledTap(source: source, runLoop: runLoop))
    }

    /// 作成の失敗をログに残す。原因の切り分けのため、権限の値も一緒に出す（design.md 7.5、N-3.5）。
    /// `CGPreflight…` の値はログにだけ使い、権限の判定には使わない（V-1・V-7 で取り消し後も true のままだった）。
    private static func logCreationFailure(reason: String) {
        Log.hotkey.error(
            "イベントタップの作成に失敗した: \(reason, privacy: .public)。\(permissionDiagnostics(), privacy: .public)"
        )
    }

    private static func permissionDiagnostics() -> String {
        "AXIsProcessTrusted=\(AXIsProcessTrusted()) CGPreflightListenEventAccess=\(CGPreflightListenEventAccess())"
            + " CGPreflightPostEventAccess=\(CGPreflightPostEventAccess())"
    }
}

/// C の関数ポインタとして渡すコールバック。キャプチャを持てないので、文脈は userInfo から取り出す（design.md 7.1）。
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        // 作成時に必ず渡しているので通常は起きない。キーボードを止めないよう、そのまま通す
        Log.hotkey.fault("イベントタップのコールバックの userInfo が nil。イベントをそのまま通す")
        return Unmanaged.passUnretained(event)
    }
    // userInfo は passUnretained で渡した TapContext。EventTapController とタップのスレッドが保持している
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
    switch context.handle(type: type, event: event) {
    case .pass:
        // 受け取ったイベントをそのまま返す。所有権は OS のまま（passUnretained）
        return Unmanaged.passUnretained(event)
    case .suppress:
        // nil を返すとイベントは破棄され、アプリにも OS にも届かない（F-7）
        return nil
    }
}
