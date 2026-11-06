import AppKit
import os

/// アクセシビリティ権限の状態。
enum PermissionStatus: Sendable, Equatable {
    /// `AXIsProcessTrusted() == true`。
    case granted
    /// `AXIsProcessTrusted() == false`。
    case notGranted
}

/// アクセシビリティ権限を 1 秒間隔で確認し、状態の変化を通知する（design.md 4 章・11 章、N-3.3、N-3.4）。
///
/// - 判定は `AXIsProcessTrusted()` だけで行う。`CGPreflightPostEventAccess()` は取り消した後も `true` のまま、
///   `CGPreflightListenEventAccess()` は入力監視の状態で Tobe では常に `false` のため（V-7、design.md 11 章）。
///   この 2 つは原因の切り分けのため、変化のときにログにだけ残す。
/// - 許可の前後とも同じ 1 秒間隔で確認する。実行中の取り消しも、ウォッチドッグ（T34、design.md 7.4）が
///   この通知で知る。権限の変更を知らせる公式の通知はないため、ポーリングする（D-20。`AXIsProcessTrusted()` は軽い）。
///
/// 使い方:
/// ```swift
/// let monitor = PermissionMonitor()   // 生成時に 1 回確認する。`status` はすぐに使える
/// let changes = monitor.statusChanges()
/// monitor.start()
/// for await status in changes { ... }
/// ```
///
/// スレッド: MainActor でだけ使う。タイマーはメインの run loop に登録する。
@MainActor
final class PermissionMonitor {
    /// 確認の間隔。V-7 で、取り消しを 1 秒以内に検出できることを確認した間隔（design.md 7.4）。
    private static let interval: TimeInterval = 1.0

    /// 最後に確認した状態。生成時の確認の結果で始まる。
    private(set) var status: PermissionStatus
    private var timer: Timer?
    /// `statusChanges()` の購読者ごとの continuation。ウォッチドッグ（T34）とモジュールの結線（T37）が別々に購読する。
    private var continuations: [UUID: AsyncStream<PermissionStatus>.Continuation] = [:]

    init() {
        status = Self.currentStatus()
        Self.logStatus(status, reason: "初期の確認")
    }

    isolated deinit {
        timer?.invalidate()
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    /// 1 秒間隔の確認を始める。すでに始めているときは何もしない。
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            // メインの run loop に登録したタイマーなので、メインスレッドで呼ばれる
            MainActor.assumeIsolated {
                self?.check()
            }
        }
        // 検出の遅れは 1〜2 秒に収めたい（N-3.3）。省電力のための多少のずれは許す
        timer.tolerance = 0.1
        // メニューを開いている間（event tracking モード）も確認を続ける。取り消しの検出が遅れると、
        // ヒントモード中のキー破棄が残ってキーボードが効かなくなり得るため（design.md 7.4）
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 確認を止める。購読中のストリームは終えない（`start()` で再開できる）。
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 状態が変わるたびに、新しい状態を流すストリームを返す。
    ///
    /// - 購読を始めた時点の状態は流さない。今の状態は `status` で読む（どちらも MainActor なので、
    ///   `status` を読んでから購読するまでの間に変化が入り込むことはない）。
    /// - 複数の購読者がそれぞれ呼んでよい。変化は 1 秒に高々 1 回なので、取りこぼさないよう上限なしで溜める。
    /// - `PermissionMonitor` が解放されるとストリームは終わる。
    func statusChanges() -> AsyncStream<PermissionStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: PermissionStatus.self,
            bufferingPolicy: .unbounded
        )
        continuation.onTermination = { [weak self] _ in
            // onTermination は任意のスレッドから呼ばれるため、MainActor に移ってから取り除く
            Task { @MainActor in
                self?.continuations[id] = nil
            }
        }
        continuations[id] = continuation
        return stream
    }

    private func check() {
        let newStatus = Self.currentStatus()
        guard newStatus != status else { return }
        status = newStatus
        Self.logStatus(newStatus, reason: "変化を検出")
        for continuation in continuations.values {
            continuation.yield(newStatus)
        }
    }

    private static func currentStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .notGranted
    }

    private static func logStatus(_ status: PermissionStatus, reason: String) {
        // CGPreflight… は判定に使わない。原因を切り分けるための参考としてだけ残す（design.md 11 章）
        let listen = CGPreflightListenEventAccess()
        let post = CGPreflightPostEventAccess()
        Log.permission.notice(
            """
            [\(reason, privacy: .public)] アクセシビリティ: \(String(describing: status), privacy: .public) \
            （参考: CGPreflightListenEventAccess=\(listen, privacy: .public) \
            CGPreflightPostEventAccess=\(post, privacy: .public)）
            """
        )
    }
}
