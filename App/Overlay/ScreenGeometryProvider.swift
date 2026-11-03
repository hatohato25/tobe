import AppKit
import CoreGraphics
import TobiCore

/// 1 枚の画面について、グローバル座標の `ScreenGeometry` と、元の `NSScreen` を組にしたもの。
///
/// オーバーレイのパネル（T44・T45）は frame に `NSScreen.frame` をそのまま使い（design.md 9.1）、
/// ラベルの配置は `geometry`（グローバル座標）で行う。両方を同じ時点の値で揃えるために組で返す。
/// `NSScreen` を持つので MainActor の中でだけ使う（`Sendable` にしない）。
struct ScreenSnapshot {
    /// グローバル座標の位置と大きさ。`geometry.id` は `NSScreen.screens` の添字。
    let geometry: ScreenGeometry
    /// 元の画面。パネルの frame（AppKit の座標）と `backingScaleFactor` はここから読む。
    let screen: NSScreen
    /// CoreGraphics のディスプレイ ID（`NSScreenNumber`）。取れない画面では nil。
    /// ログと `CGDisplayBounds` との照合（`--dump-screens`）に使う。
    let displayID: CGDirectDisplayID?
}

/// `NSScreen.screens` を `ScreenGeometry` に変換し、画面の構成の変化を通知する（design.md 9.1・9.2、D-15）。
///
/// - AppKit の座標からグローバル座標への変換は、アプリの中でこの型の `currentSnapshots()` の 1 か所だけで行う。
///   他の場所で `NSScreen.frame` を `CoordinateConverter` に渡さない。
/// - 主ディスプレイは `NSScreen.screens[0]`（AppKit の原点を持つ画面）。`NSScreen.main` はキーウィンドウのある画面で、
///   主ディスプレイとは限らないので使わない。
/// - 画面が 0 枚（`NSScreen.screens` が空。クラムシェルで外部ディスプレイを外した直後など）のときは、
///   空の配列を返し、`Log.overlay` に警告を出す。黙って空にはしない。ヒントモード側は空を受けて
///   `noScreensForHints` をログに出す（T29）。
///
/// 使い方:
/// ```swift
/// let provider = ScreenGeometryProvider()
/// let changes = provider.screenChanges()
/// for await _ in changes {
///     coordinator.screensChanged()      // T48
///     overlay.rebuildPanels(provider.currentSnapshots())  // T45
/// }
/// ```
///
/// スレッド: MainActor でだけ使う。`NSScreen` は AppKit の型なので、MainActor の外から読まない。
@MainActor
final class ScreenGeometryProvider: ScreenGeometryProviding {
    /// `screenChanges()` の購読者ごとの continuation。ヒントモードの配線（T48）とオーバーレイ（T45）が別々に購読する。
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// `didChangeScreenParametersNotification` の購読の解除に使うトークン。
    private var observation: (any NSObjectProtocol)?

    /// 生成した時点から画面の構成の変化を購読する。
    init() {
        observation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue に .main を指定したので、メインスレッドで呼ばれる
            MainActor.assumeIsolated {
                self?.screenParametersDidChange()
            }
        }
    }

    isolated deinit {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    /// 今の画面の一覧（グローバル座標）。先頭が主ディスプレイ。画面がないときは空（警告をログに出す）。
    func currentScreens() -> [ScreenGeometry] {
        currentSnapshots().map(\.geometry)
    }

    /// 今の画面の一覧を、`NSScreen` と組で返す。並びと `ScreenID` は `currentScreens()` と同じ。
    /// 画面がないときは空（警告をログに出す）。
    func currentSnapshots() -> [ScreenSnapshot] {
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            Log.overlay.error("NSScreen.screens が空のため、表示できる画面がない")
            return []
        }
        let primaryHeight = Double(primary.frame.height)
        return screens.enumerated().map { index, screen in
            ScreenSnapshot(
                geometry: ScreenGeometry(
                    id: ScreenID(rawValue: index),
                    frame: CoordinateConverter.globalRect(fromAppKit: screen.frame, primaryHeight: primaryHeight)
                ),
                screen: screen,
                displayID: Self.displayID(of: screen)
            )
        }
    }

    /// 画面の構成（台数・配置・解像度・主ディスプレイ）が変わるたびに値を流すストリームを返す。
    ///
    /// - 流れる値は「変わった」という事実だけ。新しい構成は受け取った後に `currentScreens()` /
    ///   `currentSnapshots()` で読み直す（`ScreenID` は添字なので、変化の前の値は使い回さない）。
    /// - 購読を始めた時点の構成は流さない。
    /// - 抜き差しの直後は通知が続けて届くことがある。読み直せば済むので、未処理の通知は 1 つにまとめる
    ///   （`bufferingNewest(1)`）。
    /// - 複数の購読者がそれぞれ呼んでよい。`ScreenGeometryProvider` が解放されるとストリームは終わる。
    func screenChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            // onTermination は任意のスレッドから呼ばれるため、MainActor に移ってから取り除く
            Task { @MainActor in
                self?.continuations[id] = nil
            }
        }
        continuations[id] = continuation
        return stream
    }

    private func screenParametersDidChange() {
        Log.overlay.notice("画面の構成が変わった（画面の数: \(NSScreen.screens.count, privacy: .public)）")
        for continuation in continuations.values {
            continuation.yield()
        }
    }

    /// `NSScreen.deviceDescription` の `NSScreenNumber` から CoreGraphics のディスプレイ ID を読む。
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return number.uint32Value
    }
}
