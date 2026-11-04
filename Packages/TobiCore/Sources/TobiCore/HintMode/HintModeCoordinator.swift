import Foundation

/// `HintModeCoordinator` が App にログとして渡す出来事（design.md 3.6、14 章）。
///
/// TobiCore は `os.Logger` に直接書かない（ログの出し先とカテゴリは App の `Log` が決める）。Coordinator は
/// ログに出すべき事柄をこの値にして、初期化で受け取ったクロージャに渡す。要素のタイトルや値は持たない
/// （ロール、件数、時間だけ。design.md 14 章）。
public enum HintModeLogEvent: Equatable, Sendable {
    /// 収集が値を返した（`collector`）。`elapsed` は収集を始めてから結果を受け取るまでの時間。
    /// 古いセッション（Esc の後など）の結果でも出す。そのセッションの結果が使われたかどうかは問わない。
    case collectionFinished(SessionID, elementCount: Int, elapsed: Duration)
    /// 収集結果の診断（`collector`。F-2.13）。`collectionFinished` の直後に 1 件ずつ出す。
    case collectionDiagnostic(SessionID, CollectionDiagnostic)
    /// 収集が失敗した（`collector`）。Esc などで Coordinator が止めた収集の `cancelled` もここに出る。
    case collectionFailed(SessionID, CollectionError, elapsed: Duration)
    /// 件数の上限を超えて切り捨てた要素の数（`collector`。T25、`HintModeEffect.reportTruncatedHints`）。
    case hintsTruncated(count: Int)
    /// ラベルを表示した（`overlay`）。`count` は表示を指示したラベルの数。
    case hintsShown(count: Int)
    /// 表示する画面がなく（`ScreenGeometryProviding.currentScreens()` が空）、ラベルを置けなかった（`overlay`）。
    case noScreensForHints(hintCount: Int)
    /// 操作が終わった（`action`。F-5.1、F-5.2）。`role` は対象の要素の AX ロール。
    case actionPerformed(ActionMethod, role: String)
    /// 操作が失敗した（`action`。Q-19）。この出来事の後に失敗の音を鳴らす。
    case actionFailed(ActionError, role: String)
}

/// `HintModeMachine` のエフェクトをポートの呼び出しに変える（design.md 3.6、D-2）。
///
/// UI のポート（オーバーレイ、音、画面）を呼ぶため MainActor で動く。収集（`ElementCollecting`）と
/// 操作（`ActionPerforming`）は `async` で MainActor の外で走り、結果を MainActor に戻してマシンに `send` する
/// （design.md 13 章）。エフェクトは返された順に実行する（確定は `hideHints` → `setKeySuppression(false)` → `perform`。F-5.4）。
@MainActor
public final class HintModeCoordinator {
    /// 収集の期限（design.md 8.5）。性能のための内部値で、設定項目にはしない。
    public static let defaultCollectionBudget: Duration = .milliseconds(150)

    private let collector: any ElementCollecting
    private let performer: any ActionPerforming
    private let overlay: any HintOverlayPresenting
    private let gate: any KeySuppressionGate
    private let feedback: any FeedbackPlaying
    private let screens: any ScreenGeometryProviding
    private let settings: @MainActor () -> TobiSettings
    private let log: @MainActor (HintModeLogEvent) -> Void
    private let collectionBudget: Duration
    private let now: @MainActor () -> ContinuousClock.Instant

    private var machine = HintModeMachine()
    /// 今のセッションのラベルの見た目。セッションの開始時（`startCollection` が出たとき）にだけ差し替える（S-0.4）。
    private var sessionAppearance: LabelAppearance?
    /// 実行中の収集と操作。収集は `cancelCollection` で止めるために、`SessionID` で引けるようにしておく。
    private var inFlight: [WorkKey: Task<Void, Never>] = [:]
    private var lastActionNumber: UInt64 = 0

    private enum WorkKey: Hashable {
        case collection(SessionID)
        case action(UInt64)
    }

    /// - Parameters:
    ///   - settings: 起動キーの単独タップを受けるたびに呼ぶ。新しいセッションが始まったときの値を、
    ///     そのセッションの間は使い続ける（S-0.4）。
    ///   - log: ログに出す出来事を受け取る。App が `Log` のカテゴリに振り分ける。
    ///   - collectionBudget: 収集を始めてから期限までの時間（design.md 8.5）。
    ///   - now: 期限と所要時間の計算に使う現在時刻。テストでは進め方を制御できる時計に差し替える。
    public init(
        collector: any ElementCollecting,
        performer: any ActionPerforming,
        overlay: any HintOverlayPresenting,
        gate: any KeySuppressionGate,
        feedback: any FeedbackPlaying,
        screens: any ScreenGeometryProviding,
        settings: @escaping @MainActor () -> TobiSettings,
        log: @escaping @MainActor (HintModeLogEvent) -> Void,
        collectionBudget: Duration = HintModeCoordinator.defaultCollectionBudget,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.collector = collector
        self.performer = performer
        self.overlay = overlay
        self.gate = gate
        self.feedback = feedback
        self.screens = screens
        self.settings = settings
        self.log = log
        self.collectionBudget = collectionBudget
        self.now = now
    }

    /// 今の状態（signpost の区間の終わりの判定やテストのため）。
    public var state: HintModeState {
        machine.state
    }

    // MARK: - 入力

    /// 起動キーの単独タップ（F-1）。
    public func triggerTapped() {
        let current = settings()
        let effects = machine.send(.triggerTapped(alphabet: current.alphabet))
        // 再タップ（暫定 Q-3）はマシンが無視するので、見た目を差し替えるのは新しいセッションが始まったときだけ
        if effects.contains(where: Self.isStartCollection) {
            sessionAppearance = current.appearance
        }
        run(effects)
    }

    /// ヒントモード中の keyDown（F-4、F-6）。
    public func keyPressed(_ input: HintKeyInput) {
        send(.key(input))
    }

    /// マウスのボタンが押された（F-6.3、暫定 Q-10）。
    public func pointerDown() {
        send(.pointerDown)
    }

    /// 画面構成が変わった（F-6.3、暫定 Q-10）。
    public func screensChanged() {
        send(.screensChanged)
    }

    /// 実行中の収集と操作がすべて終わるまで待つ。テストで結果を確かめるために使う。
    func waitForPendingWork() async {
        // 各 Task は終わる直前に自分を inFlight から外す。待っている間に新しい Task が増えても、空になるまで待つ
        while let task = inFlight.values.first {
            await task.value
        }
    }

    // MARK: - エフェクト

    private func send(_ event: HintModeEvent) {
        run(machine.send(event))
    }

    private func run(_ effects: [HintModeEffect]) {
        for effect in effects {
            run(effect)
        }
    }

    private func run(_ effect: HintModeEffect) {
        switch effect {
        case .setKeySuppression(let suppressing):
            gate.setSuppressing(suppressing)
        case .startCollection(let sessionID):
            startCollection(sessionID)
        case .cancelCollection(let sessionID):
            // 止めた収集の結果が後から届いても、マシンが古い結果として捨てる（F-6.2）
            inFlight[.collection(sessionID)]?.cancel()
        case .reportTruncatedHints(let count):
            log(.hintsTruncated(count: count))
        case .showHints(let hints):
            showHints(hints)
        case .updateHints(let visible, let typed):
            overlay.update(visibleIDs: visible, typedCount: typed.count)
        case .hideHints:
            overlay.hide()
        case .perform(let action, let element):
            perform(action, on: element)
        case .playFailure:
            feedback.playFailure()
        }
    }

    private static func isStartCollection(_ effect: HintModeEffect) -> Bool {
        if case .startCollection = effect { true } else { false }
    }

    // MARK: - 収集

    private func startCollection(_ sessionID: SessionID) {
        let startedAt = now()
        let deadline = startedAt.advanced(by: collectionBudget)
        let collector = self.collector
        let key = WorkKey.collection(sessionID)
        // Task は MainActor を引き継ぐ。collect は nonisolated な async なので、走査は MainActor の外で行われる
        inFlight[key] = Task { [weak self] in
            let outcome: Result<CollectionResult, CollectionError>
            do throws(CollectionError) {
                outcome = .success(try await collector.collect(deadline: deadline))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            finishCollection(sessionID, outcome: outcome, startedAt: startedAt)
            inFlight[key] = nil
        }
    }

    private func finishCollection(
        _ sessionID: SessionID,
        outcome: Result<CollectionResult, CollectionError>,
        startedAt: ContinuousClock.Instant
    ) {
        let elapsed = now() - startedAt
        switch outcome {
        case .success(let result):
            log(.collectionFinished(sessionID, elementCount: result.elements.count, elapsed: elapsed))
            for diagnostic in result.diagnostics {
                log(.collectionDiagnostic(sessionID, diagnostic))
            }
            send(.collectionSucceeded(sessionID, result))
        case .failure(let error):
            log(.collectionFailed(sessionID, error, elapsed: elapsed))
            send(.collectionFailed(sessionID, error))
        }
    }

    // MARK: - 表示

    private func showHints(_ hints: [Hint]) {
        guard let appearance = sessionAppearance else {
            // showHints は startCollection の後にしか出ず、そのとき必ず見た目を設定している
            preconditionFailure("セッションの見た目が決まる前に showHints が出た")
        }
        let placements = HintPlacement.place(hints, screens: screens.currentScreens())
        if placements.isEmpty {
            // 画面が 1 枚もないときだけ起きる。黙って何も出さないままにしないよう、ログに残す
            log(.noScreensForHints(hintCount: hints.count))
        } else {
            log(.hintsShown(count: placements.count))
        }
        overlay.show(placements, appearance: appearance)
    }

    // MARK: - 操作

    private func perform(_ action: HintAction, on element: CollectedElement) {
        lastActionNumber += 1
        let key = WorkKey.action(lastActionNumber)
        let performer = self.performer
        // 操作の完了は待たない。マシンはすでに idle で、次の単独タップを受け付けられる（D-2、F-5.5）
        inFlight[key] = Task { [weak self] in
            let outcome: Result<ActionMethod, ActionError>
            do throws(ActionError) {
                outcome = .success(try await performer.perform(action, on: element))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            finishAction(outcome, element: element)
            inFlight[key] = nil
        }
    }

    private func finishAction(_ outcome: Result<ActionMethod, ActionError>, element: CollectedElement) {
        switch outcome {
        case .success(let method):
            log(.actionPerformed(method, role: element.role))
        case .failure(let error):
            log(.actionFailed(error, role: element.role))
            // どの失敗でも音で知らせる（Q-19）
            feedback.playFailure()
        }
    }
}
