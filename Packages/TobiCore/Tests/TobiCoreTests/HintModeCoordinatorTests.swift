import CoreGraphics
import Testing

@testable import TobiCore

/// フェイクのポートをつないだ `HintModeCoordinator` と、その呼び出しの記録。
@MainActor
final class CoordinatorHarness {
    let journal = CallJournal()
    let clock = FakeClock()
    let collector: FakeCollector
    let overlay: FakeOverlay
    let screens: FakeScreens
    let coordinator: HintModeCoordinator
    private let settingsBox: SettingsBox

    static let screen = ScreenGeometry(
        id: ScreenID(rawValue: 0),
        frame: GlobalRect(rect: CGRect(x: 0, y: 0, width: 4000, height: 4000))
    )

    init(
        actionOutcome: Result<ActionMethod, ActionError> = .success(.axPress),
        settings: TobiSettings = .defaults
    ) {
        collector = FakeCollector(journal: journal)
        overlay = FakeOverlay(journal: journal)
        screens = FakeScreens(screens: [Self.screen])
        let settingsBox = SettingsBox(settings)
        self.settingsBox = settingsBox
        let journal = journal
        let clock = clock
        coordinator = HintModeCoordinator(
            collector: collector,
            performer: FakePerformer(journal: journal, outcome: actionOutcome),
            overlay: overlay,
            gate: FakeGate(journal: journal),
            feedback: FakeFeedback(journal: journal),
            screens: screens,
            settings: { settingsBox.value },
            log: { journal.append(.log($0)) },
            now: { clock.now }
        )
    }

    /// `settings` のクロージャが返す値。テストの途中で変えて、セッション中に読み直さないことを確かめる。
    var settings: TobiSettings {
        get { settingsBox.value }
        set { settingsBox.value = newValue }
    }

    var entries: [CallJournal.Entry] {
        journal.entries
    }

    var logEvents: [HintModeLogEvent] {
        entries.compactMap {
            if case .log(let event) = $0 { event } else { nil }
        }
    }

    var sessionID: SessionID? {
        switch coordinator.state {
        case .idle: nil
        case .collecting(let context): context.sessionID
        case .selecting(let context): context.sessionID
        }
    }

    /// 結果を用意してから起動し、ラベルが表示されるまで進める。記録はその後から取り直せるよう、件数を返す。
    @discardableResult
    func startSelecting(with result: CollectionResult) async -> Int {
        collector.respond(with: .success(result))
        coordinator.triggerTapped()
        await coordinator.waitForPendingWork()
        return entries.count
    }

    /// 最後に表示したラベルのうち、`label` の要素の ID。
    func elementID(labeled label: String) throws -> ElementID {
        let placement = try #require(overlay.shown.last?.placements.first { $0.label == label })
        return placement.elementID
    }
}

@Suite("HintModeCoordinator: 起動から確定まで（design.md 3.6、5.2）")
@MainActor
struct HintModeCoordinatorFlowTests {
    @Test("起動 → 収集 → 表示 → 絞り込み → 確定 → 操作の順にポートを呼ぶ")
    func fullFlow() async throws {
        let harness = CoordinatorHarness(settings: try settings(alphabet: HintModeFixtures.sadf()))
        let result = HintModeFixtures.result(elementCount: 6)

        await harness.startSelecting(with: result)

        #expect(
            harness.entries == [
                .setSuppressing(true),
                .collect,
                .log(.collectionFinished(SessionID(rawValue: 1), elementCount: 6, elapsed: .zero)),
                .log(.hintsShown(count: 6)),
                .show(count: 6),
            ]
        )
        let shown = try #require(harness.overlay.shown.last)
        #expect(Set(shown.placements.map(\.label)) == ["a", "sa", "d", "sd", "f", "ss"])
        let target = try harness.elementID(labeled: "sa")
        let narrowed = try [
            harness.elementID(labeled: "sa"), harness.elementID(labeled: "sd"), harness.elementID(labeled: "ss"),
        ]

        let beforeKeys = harness.entries.count
        harness.coordinator.keyPressed(.character("s"))
        harness.coordinator.keyPressed(.character("a"))
        await harness.coordinator.waitForPendingWork()

        #expect(
            Array(harness.entries.dropFirst(beforeKeys)) == [
                .update(Set(narrowed), typedCount: 1),
                // 確定はオーバーレイを消し、キー破棄を解いてから操作する（F-5.4）
                .hide,
                .setSuppressing(false),
                .perform(.leftClick, target),
                .log(.actionPerformed(.axPress, role: "AXButton")),
            ]
        )
        #expect(harness.coordinator.state == .idle)
    }

    @Test("絞り込みと backspace のたびに、入力済みの文字数をオーバーレイに渡す")
    func passesTypedCountToOverlay() async throws {
        let harness = CoordinatorHarness(settings: try settings(alphabet: HintModeFixtures.sadf()))
        let before = await harness.startSelecting(with: HintModeFixtures.result(elementCount: 6))
        let all = try ["a", "sa", "d", "sd", "f", "ss"].map { try harness.elementID(labeled: $0) }
        let narrowed = try ["sa", "sd", "ss"].map { try harness.elementID(labeled: $0) }

        harness.coordinator.keyPressed(.character("s"))
        harness.coordinator.keyPressed(.backspace)

        #expect(
            Array(harness.entries.dropFirst(before)) == [
                .update(Set(narrowed), typedCount: 1),
                // 戻したら入力済みの文字はなくなる（薄くした文字を元に戻す）
                .update(Set(all), typedCount: 0),
            ]
        )
    }

    @Test("収集の期限は、起動した時刻の 150ms 後")
    func deadlineIsBudgetAfterTrigger() async {
        let harness = CoordinatorHarness()
        let triggeredAt = harness.clock.now

        await harness.startSelecting(with: HintModeFixtures.result(elementCount: 1))

        #expect(harness.collector.deadlines == [triggeredAt.advanced(by: .milliseconds(150))])
    }

    @Test("収集にかかった時間を、差し替えた時計で測ってログに渡す")
    func collectionElapsedUsesInjectedClock() async {
        let harness = CoordinatorHarness()

        harness.coordinator.triggerTapped()
        await harness.collector.waitUntilWaiting(count: 1)
        harness.clock.advance(by: .milliseconds(40))
        harness.collector.respond(with: .success(HintModeFixtures.result(elementCount: 2)))
        await harness.coordinator.waitForPendingWork()

        #expect(
            harness.logEvents.first
                == .collectionFinished(SessionID(rawValue: 1), elementCount: 2, elapsed: .milliseconds(40))
        )
    }

    @Test("ラベル入力中の Esc でラベルを消し、キー破棄を解く")
    func escapeWhileSelecting() async {
        let harness = CoordinatorHarness()
        let before = await harness.startSelecting(with: HintModeFixtures.result(elementCount: 3))

        harness.coordinator.keyPressed(.escape)

        #expect(Array(harness.entries.dropFirst(before)) == [.hide, .setSuppressing(false)])
        #expect(harness.coordinator.state == .idle)
    }

    @Test("操作の終わりを待たずに、次の単独タップで新しいセッションを始める（F-5.5）")
    func nextTriggerAfterConfirmation() async throws {
        let harness = CoordinatorHarness()
        await harness.startSelecting(with: HintModeFixtures.result(elementCount: 1))
        harness.collector.respond(with: .success(HintModeFixtures.result(elementCount: 2)))

        // 1 件ならラベルは `s`。確定した直後（操作の Task がまだ走っていない時点）に次のタップを送る
        harness.coordinator.keyPressed(.character("s"))
        harness.coordinator.triggerTapped()

        #expect(harness.sessionID == SessionID(rawValue: 2))
        await harness.coordinator.waitForPendingWork()
        #expect(harness.overlay.shown.map(\.placements.count) == [1, 2])
        #expect(harness.logEvents.contains(.actionPerformed(.axPress, role: "AXButton")))
    }

    @Test("件数の上限を超えたときは、表示の前に切り捨てた件数をログに渡す")
    func truncatedCountIsLogged() async {
        let harness = CoordinatorHarness()

        await harness.startSelecting(with: HintModeFixtures.result(elementCount: HintPipeline.maxHints + 3))

        #expect(
            Array(harness.logEvents.dropFirst()) == [
                .hintsTruncated(count: 3),
                .hintsShown(count: HintPipeline.maxHints),
            ]
        )
        #expect(harness.overlay.shown.map(\.placements.count) == [HintPipeline.maxHints])
    }

    @Test("収集結果の診断を、すべて順にログに渡す（F-2.13）")
    func diagnosticsAreLogged() async {
        let harness = CoordinatorHarness()
        let pid = ProcessID(rawValue: 42)
        let diagnostics: [CollectionDiagnostic] = [
            .deadlineExceeded(pid, collected: 3),
            .readFailed(pid, .cannotComplete, count: 2),
            .windowListEntrySkipped(reason: "missing bounds"),
        ]
        let base = HintModeFixtures.result(elementCount: 1)
        let result = CollectionResult(windows: base.windows, elements: base.elements, diagnostics: diagnostics)

        await harness.startSelecting(with: result)

        let session = SessionID(rawValue: 1)
        #expect(
            harness.logEvents == [
                .collectionFinished(session, elementCount: 1, elapsed: .zero),
                .collectionDiagnostic(session, diagnostics[0]),
                .collectionDiagnostic(session, diagnostics[1]),
                .collectionDiagnostic(session, diagnostics[2]),
                .hintsShown(count: 1),
            ]
        )
    }

    @Test("画面が 1 枚もないときは、置けなかったことをログに渡す")
    func noScreensIsLogged() async {
        let harness = CoordinatorHarness()
        harness.screens.screens = []

        await harness.startSelecting(with: HintModeFixtures.result(elementCount: 2))

        #expect(harness.logEvents.last == .noScreensForHints(hintCount: 2))
        #expect(harness.overlay.shown.map(\.placements.count) == [0])
    }
}

/// 文字セットと見た目だけを変えた設定。
func settings(
    alphabet: HintAlphabet,
    appearance: LabelAppearance = .defaults
) -> TobiSettings {
    TobiSettings(triggerKey: .rightCommand, alphabet: alphabet, appearance: appearance)
}

/// テストの途中で差し替えられる設定の入れ物。
@MainActor
final class SettingsBox {
    var value: TobiSettings

    init(_ value: TobiSettings) {
        self.value = value
    }
}
