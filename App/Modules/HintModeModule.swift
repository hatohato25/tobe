import AppKit
import TobeCore

/// ヒントモード（要素の収集、ラベル表示、入力の絞り込み、操作の実行）を担当するモジュール（design.md 1.1、3.6、T48）。
///
/// `HintModeCoordinator`（TobeCore）に App の実物のポートを渡し、`hotkey` の通知と画面の構成の変化を結ぶ。
/// - 収集: `AXElementCollector`。収集した参照は `ElementHandleRegistry` に入り、操作のときに `AXActionPerformer` が引く。
/// - 操作: `AXActionPerformer`。`AXPress` が非対応の要素は `MouseClickPoster` で中心をクリックする（T46 の注入口）。
/// - 表示: `OverlayController`。Coordinator と**同じ** `ScreenGeometryProvider` から画面を読む（`ScreenID` をそろえるため）。
/// - キー破棄の OFF: `hotkey.eventTap`（ON はタップのスレッドが単独タップの判定時に自分で立てる。D-8）。
/// - 設定: `settingsProvider`。単独タップのたびに Coordinator が読む。
///
/// 通知の結び方:
/// - `hotkey.tapEvents`（購読者は 1 つだけ。ここで購読する）:
///   `.triggered` → signpost の区間を始めて `triggerTapped()`、`.hintKey` → `KeyTranslator` で変換して `keyPressed(_:)`、
///   `.pointerDown` → `pointerDown()`、`.tapReenabled` → ログだけ
/// - `ScreenGeometryProvider.screenChanges()`: `screensChanged()` → `overlay.rebuildPanels(for:)` の順
///   （OverlayController は自分では購読しない。T45）
///
/// セッションの終わり（`coordinator.state` が `.idle` に戻ったとき）に、signpost の区間を閉じ、
/// 要素の参照の対応表を空にする（`registry.removeAll()`）。Coordinator は状態の変化を知らせないため、
/// 状態が変わりうる箇所（入力を渡した直後と、収集の結果が届いた直後）で確かめる。
///
/// スレッド: MainActor でだけ使う（Coordinator・オーバーレイ・`KeyTranslator` が MainActor のため）。
@MainActor
final class HintModeModule: AppModule {
    /// ヒントモードの設定の読み出し口。Coordinator が単独タップのたびに呼び、新しいセッションの間はその値を使う（S-0.4）。
    ///
    /// 設定画面がまだ結線されていないため、今は既定値を返す。`SettingsModule`（T54）が
    /// `SettingsModel` の値を返すクロージャに差し替える。いつ差し替えてもよく、差し替えた後に始まるセッションから使われる。
    var settingsProvider: @MainActor () -> TobeSettings {
        get { settingsSource.read }
        set { settingsSource.read = newValue }
    }

    private let hotkey: HotkeyModule
    private let screens: ScreenGeometryProvider
    private let overlay: OverlayController
    private let registry: ElementHandleRegistry
    private let collector: AXElementCollector
    private let performer: AXActionPerformer
    private let feedback: SystemFeedback
    private let settingsSource = SettingsSource()

    /// Coordinator の `settings` と `log` のクロージャが `self` を参照するため、全プロパティの初期化後に作る。
    private lazy var coordinator = makeCoordinator()

    /// 今のセッションの `hintSession` の区間。`.triggered` で始め、`idle` に戻ったのを確かめたら閉じる。
    private var sessionSignpost: HintSessionSignpost?
    /// 結果がまだ届いていない操作の数。操作は idle に戻った後に GCD のキューで対応表を引くため、
    /// これが 0 になるまで `registry.removeAll()` を待つ。
    private var pendingActionCount = 0

    private var tapEventsTask: Task<Void, Never>?
    private var screenChangesTask: Task<Void, Never>?
    private let contentEnabler = ContentAccessibilityEnabler()
    private var activationObserver: NSObjectProtocol?

    init(hotkey: HotkeyModule) {
        self.hotkey = hotkey
        let screens = ScreenGeometryProvider()
        let registry = ElementHandleRegistry()
        self.screens = screens
        self.registry = registry
        overlay = OverlayController(screens: screens.currentSnapshots())
        collector = AXElementCollector(registry: registry, contentEnabler: contentEnabler)
        let poster = MouseClickPoster()
        performer = AXActionPerformer(
            client: AXClient(),
            lookUpElement: registry.lookup,
            fallbackClick: { frame throws(ActionError) in try poster.clickCenter(of: frame) }
        )
        feedback = SystemFeedback()
    }

    func start() {
        guard tapEventsTask == nil else {
            Log.app.fault("HintModeModule.start() が 2 回呼ばれた。2 回目は何もしない")
            return
        }
        // tapEvents は生成時から溜めているので、ここで購読を始めても取りこぼさない
        let tapEvents = hotkey.tapEvents
        tapEventsTask = Task { [weak self] in
            for await event in tapEvents {
                self?.handle(event)
            }
        }
        let screenChanges = screens.screenChanges()
        screenChangesTask = Task { [weak self] in
            for await _ in screenChanges {
                self?.screensDidChange()
            }
        }
        startEnablingContentExposure()
        Log.app.notice("HintModeModule を開始した")
    }

    /// 前面のアプリが対象なら、ラベルを出す前に中身の公開を頼んでおく。公開に数秒かかるので、最初のタップに間に合わせるため。
    private func startEnablingContentExposure() {
        let enabler = contentEnabler
        let enable: @Sendable (NSRunningApplication?) -> Void = { app in
            guard let pid = app?.processIdentifier else { return }
            let processID = ProcessID(rawValue: pid)
            // AX の IPC は MainActor で待たない
            DispatchQueue.global(qos: .userInitiated).async { enabler.enableIfNeeded(for: processID) }
        }
        enable(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            enable(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    func stop() {
        tapEventsTask?.cancel()
        tapEventsTask = nil
        screenChangesTask?.cancel()
        screenChangesTask = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        overlay.hide()
        // セッションの途中で止めた場合に、キーが破棄されたまま残らないようにする（変化がなければ何もしない）
        hotkey.eventTap.setSuppressing(false)
        sessionSignpost?.end()
        sessionSignpost = nil
        registry.removeAll()
    }

    // MARK: - 組み立て

    private func makeCoordinator() -> HintModeCoordinator {
        HintModeCoordinator(
            collector: collector,
            performer: performer,
            overlay: overlay,
            gate: hotkey.eventTap,
            feedback: feedback,
            screens: screens,
            // self を捕まえない（Coordinator → クロージャ → self → Coordinator の循環を作らない）。
            // weak self にすると、self がないときに返す設定を決める暗黙のフォールバックが要るため、読み出し口だけを持つ
            settings: { [settingsSource] in settingsSource.read() },
            // ログはモジュールが解放された後なら捨ててよい（戻り値がない）
            log: { [weak self] event in self?.handleLog(event) }
        )
    }

    // MARK: - 通知

    private func handle(_ event: TapEvent) {
        switch event {
        case .triggered:
            handleTrigger()
        case .hintKey(let keyCode, let flags, let isRepeat):
            handleHintKey(keyTranslator.hintKeyInput(keyCode: keyCode, flags: flags, isRepeat: isRepeat))
        case .pointerDown:
            coordinator.pointerDown()
            finishSessionIfIdle()
        case .tapReenabled(let reason):
            // 再有効化そのもののログはタップ側（TapContext）が出している。ヒントモードの状態は変えない
            Log.hotkey.info("ヒントモード: タップの再有効化の通知を受けた（\(reason.rawValue, privacy: .public)）")
        }
    }

    private var keyTranslator: KeyTranslator {
        hotkey.keyTranslator
    }

    private func handleTrigger() {
        if coordinator.state == .idle {
            // 前のセッションの終わりをまだ確かめていなければ、ここで閉じる（区間は同時に 1 つだけ）
            finishSessionIfIdle()
            // N-1.1 の計測の起点。Coordinator に渡す前に始める
            sessionSignpost = Signposts.beginHintSession()
        }
        // ヒントモード中の再タップ（暫定 Q-3）は Coordinator が無視する。区間は始め直さない
        coordinator.triggerTapped()
        finishSessionIfIdle()
    }

    private func handleHintKey(_ input: HintKeyInput) {
        let wasSelecting = if case .selecting = coordinator.state { true } else { false }
        coordinator.keyPressed(input)
        // ラベル入力中に文字で idle に戻るのは確定したときだけ（HintModeMachine: confirmed → perform）。
        // 操作は idle の後に対応表を引くので、結果が届くまで対応表を空にしない
        if wasSelecting, case .character = input, coordinator.state == .idle {
            pendingActionCount += 1
        }
        finishSessionIfIdle()
    }

    private func screensDidChange() {
        // ヒントモード中ならここで終わる（暫定 Q-10）。パネルの作り直しはその後（T45）
        coordinator.screensChanged()
        overlay.rebuildPanels(for: screens.currentSnapshots())
        finishSessionIfIdle()
    }

    private func handleLog(_ event: HintModeLogEvent) {
        LogEventRouter.route(event)
        switch event {
        case .hintsShown(let count):
            Signposts.hintsBuilt(hintCount: count)
        case .noScreensForHints(let hintCount):
            Signposts.hintsBuilt(hintCount: hintCount)
        case .collectionFinished, .collectionFailed:
            // この出来事は、Coordinator がマシンに結果を渡す直前に届く。渡した後（同じ MainActor の処理の後）に
            // 状態を確かめるため、次の MainActor の処理に回す（0 件・失敗で idle に戻る場合）
            Task { [weak self] in
                self?.finishSessionIfIdle()
            }
        case .actionPerformed, .actionFailed:
            actionDidFinish()
        case .collectionDiagnostic, .hintsTruncated:
            break
        }
    }

    // MARK: - セッションの終わり

    /// `coordinator.state` が `.idle` で、区間が開いていれば、セッションを閉じる。何度呼んでもよい。
    private func finishSessionIfIdle() {
        guard coordinator.state == .idle, let signpost = sessionSignpost else { return }
        signpost.end()
        sessionSignpost = nil
        releaseHandlesIfUnused()
    }

    private func actionDidFinish() {
        guard pendingActionCount > 0 else {
            // 確定の検出（handleHintKey）と Coordinator の操作の数が合っていない。対応表は次の収集で作り直される
            Log.action.fault("操作の結果が、確定として数えていない操作から届いた")
            return
        }
        pendingActionCount -= 1
        releaseHandlesIfUnused()
    }

    /// 待機中で、結果を待っている操作がなければ、要素の参照の対応表を空にする。
    ///
    /// 新しいセッションの収集中に呼ぶと、`removeAll()` が世代を進めてその収集を取り消してしまうため、idle のときだけにする
    /// （収集中なら、その収集の `beginCollection()` がすでに古い対応を消している）。
    private func releaseHandlesIfUnused() {
        guard pendingActionCount == 0, coordinator.state == .idle else { return }
        registry.removeAll()
    }
}

/// `settingsProvider` の実体。Coordinator の `settings` クロージャがモジュール自身を捕まえずに、
/// T54 が差し替えた後の読み出し口を呼べるようにするための入れ物。
@MainActor
private final class SettingsSource {
    /// 設定画面がまだ結線されていないため、既定値を返す（T54 が差し替える）。
    var read: @MainActor () -> TobeSettings = { TobeSettings.defaults }
}
