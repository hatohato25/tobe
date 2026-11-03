import Testing

@testable import TobiCore

/// 収集中にヒントモードを抜ける入力（design.md 5.2 の collecting の行）。
enum CollectionInterruption: String, CaseIterable, Sendable {
    case escape
    case pointerDown
    case screensChanged

    @MainActor
    func send(to coordinator: HintModeCoordinator) {
        switch self {
        case .escape: coordinator.keyPressed(.escape)
        case .pointerDown: coordinator.pointerDown()
        case .screensChanged: coordinator.screensChanged()
        }
    }
}

@Suite("HintModeCoordinator: 収集のキャンセルと古い結果（F-6.2）")
@MainActor
struct HintModeCoordinatorCancellationTests {
    @Test("収集中に抜けると Task をキャンセルし、後から届いた結果を捨てる", arguments: CollectionInterruption.allCases)
    func interruptionDiscardsLateResult(interruption: CollectionInterruption) async {
        let harness = CoordinatorHarness()
        harness.coordinator.triggerTapped()
        await harness.collector.waitUntilWaiting(count: 1)

        interruption.send(to: harness.coordinator)

        #expect(harness.entries == [.setSuppressing(true), .collect, .setSuppressing(false)])
        #expect(harness.collector.cancelledCallCount == 1)
        #expect(harness.coordinator.state == .idle)

        // キャンセルに応じない収集から、結果が遅れて届く
        harness.collector.respond(with: .success(HintModeFixtures.result(elementCount: 3)))
        await harness.coordinator.waitForPendingWork()

        #expect(harness.overlay.shown.isEmpty)
        #expect(!harness.entries.contains(.playFailure))
        #expect(harness.coordinator.state == .idle)
        // 届いた結果の記録はログに残す（使われなかったかどうかはセッションの ID で分かる）
        #expect(
            harness.logEvents == [.collectionFinished(SessionID(rawValue: 1), elementCount: 3, elapsed: .zero)]
        )
    }

    @Test("前のセッションの結果が、次のセッションの収集中に届いても捨てる")
    func staleResultDuringNextSession() async {
        let harness = CoordinatorHarness()
        harness.coordinator.triggerTapped()
        await harness.collector.waitUntilWaiting(count: 1)
        harness.coordinator.keyPressed(.escape)
        harness.coordinator.triggerTapped()
        await harness.collector.waitUntilWaiting(count: 2)

        // 先に呼ばれた（1 回目のセッションの）収集から先に返る
        harness.collector.respond(with: .success(HintModeFixtures.result(elementCount: 5)))
        harness.collector.respond(with: .success(HintModeFixtures.result(elementCount: 2)))
        await harness.coordinator.waitForPendingWork()

        #expect(harness.overlay.shown.map(\.placements.count) == [2])
        #expect(harness.sessionID == SessionID(rawValue: 2))
        #expect(harness.collector.cancelledCallCount == 1)
    }

    @Test("キャンセルされた収集が cancelled で終わっても、音は鳴らさない")
    func cancelledFailureIsSilent() async {
        let harness = CoordinatorHarness()
        harness.coordinator.triggerTapped()
        await harness.collector.waitUntilWaiting(count: 1)
        harness.coordinator.keyPressed(.escape)

        harness.collector.respond(with: .failure(.cancelled))
        await harness.coordinator.waitForPendingWork()

        #expect(!harness.entries.contains(.playFailure))
        #expect(harness.logEvents == [.collectionFailed(SessionID(rawValue: 1), .cancelled, elapsed: .zero)])
    }

    @Test("収集中の再タップは無視し、収集を続ける（暫定 Q-3）")
    func retapWhileCollectingIsIgnored() async {
        let harness = CoordinatorHarness()
        harness.coordinator.triggerTapped()
        await harness.collector.waitUntilWaiting(count: 1)

        harness.coordinator.triggerTapped()
        harness.collector.respond(with: .success(HintModeFixtures.result(elementCount: 2)))
        await harness.coordinator.waitForPendingWork()

        #expect(harness.collector.deadlines.count == 1)
        #expect(harness.overlay.shown.map(\.placements.count) == [2])
    }
}

@Suite("HintModeCoordinator: 失敗の音とログ（Q-11、Q-19）")
@MainActor
struct HintModeCoordinatorFailureTests {
    @Test("要素が 0 件ならラベルを出さず、キー破棄を解いて音を鳴らす（暫定 Q-11）")
    func emptyResultPlaysFailure() async {
        let harness = CoordinatorHarness()

        await harness.startSelecting(with: HintModeFixtures.result(elementCount: 0))

        #expect(
            harness.entries == [
                .setSuppressing(true),
                .collect,
                .log(.collectionFinished(SessionID(rawValue: 1), elementCount: 0, elapsed: .zero)),
                .setSuppressing(false),
                .playFailure,
            ]
        )
        #expect(harness.overlay.shown.isEmpty)
        #expect(harness.coordinator.state == .idle)
    }

    @Test(
        "収集が失敗したら理由をログに渡し、キー破棄を解いて音を鳴らす",
        arguments: [CollectionError.accessibilityNotTrusted, .windowListUnavailable]
    )
    func collectionFailurePlaysFailure(error: CollectionError) async {
        let harness = CoordinatorHarness()
        harness.collector.respond(with: .failure(error))

        harness.coordinator.triggerTapped()
        await harness.coordinator.waitForPendingWork()

        #expect(
            harness.entries == [
                .setSuppressing(true),
                .collect,
                .log(.collectionFailed(SessionID(rawValue: 1), error, elapsed: .zero)),
                .setSuppressing(false),
                .playFailure,
            ]
        )
        #expect(harness.coordinator.state == .idle)
    }

    @Test(
        "操作が失敗したらログに渡し、音を鳴らす（Q-19）",
        arguments: [
            ActionError.elementNotFound(ElementID(rawValue: 1)),
            .actionUnsupported,
            .accessibility(.cannotComplete),
            .eventCreationFailed,
        ]
    )
    func actionFailurePlaysFailure(error: ActionError) async throws {
        let harness = CoordinatorHarness(actionOutcome: .failure(error))
        let before = await harness.startSelecting(with: HintModeFixtures.result(elementCount: 1))
        let target = try harness.elementID(labeled: "s")

        harness.coordinator.keyPressed(.character("s"))
        await harness.coordinator.waitForPendingWork()

        #expect(
            Array(harness.entries.dropFirst(before)) == [
                .hide,
                .setSuppressing(false),
                .perform(.leftClick, target),
                .log(.actionFailed(error, role: "AXButton")),
                .playFailure,
            ]
        )
        #expect(harness.coordinator.state == .idle)
    }

    @Test("代替クリックで操作できたら、その方法をログに渡す（F-5.2）")
    func mouseClickIsLogged() async {
        let harness = CoordinatorHarness(actionOutcome: .success(.mouseClick))
        await harness.startSelecting(with: HintModeFixtures.result(elementCount: 1))

        harness.coordinator.keyPressed(.character("s"))
        await harness.coordinator.waitForPendingWork()

        #expect(harness.logEvents.last == .actionPerformed(.mouseClick, role: "AXButton"))
        #expect(!harness.entries.contains(.playFailure))
    }
}

@Suite("HintModeCoordinator: 設定はセッションの開始時に読む（S-0.4）")
@MainActor
struct HintModeCoordinatorSettingsTests {
    static let largeAppearance: LabelAppearance = {
        do {
            return try LabelAppearance(
                fontSize: 24,
                textColor: RGBAColor(hex: "#FFFFFFFF"),
                backgroundColor: RGBAColor(hex: "#000000FF")
            )
        } catch {
            preconditionFailure("テスト用の見た目が不正: \(error)")
        }
    }()

    @Test("セッション中に設定が変わっても、開始時の文字セットと見た目を使う")
    func settingsAreFixedDuringSession() async throws {
        let harness = CoordinatorHarness(settings: try settings(alphabet: HintModeFixtures.sadf()))
        harness.coordinator.triggerTapped()
        await harness.collector.waitUntilWaiting(count: 1)

        harness.settings = settings(alphabet: .vimiumDefault, appearance: Self.largeAppearance)
        // 収集中の再タップ（無視される）でも、見た目は差し替えない
        harness.coordinator.triggerTapped()
        harness.collector.respond(with: .success(HintModeFixtures.result(elementCount: 6)))
        await harness.coordinator.waitForPendingWork()

        let shown = try #require(harness.overlay.shown.last)
        #expect(Set(shown.placements.map(\.label)) == ["a", "sa", "d", "sd", "f", "ss"])
        #expect(shown.appearance == .defaults)
    }

    @Test("次のセッションでは、変更後の設定を使う")
    func nextSessionUsesNewSettings() async throws {
        let harness = CoordinatorHarness(settings: try settings(alphabet: HintModeFixtures.sadf()))
        await harness.startSelecting(with: HintModeFixtures.result(elementCount: 2))
        harness.coordinator.keyPressed(.escape)

        harness.settings = settings(alphabet: .vimiumDefault, appearance: Self.largeAppearance)
        await harness.startSelecting(with: HintModeFixtures.result(elementCount: 6))

        let shown = try #require(harness.overlay.shown.last)
        // 6 件なら、sadf では 2 文字のラベルが混じり、既定の 14 文字では 1 文字だけになる
        let expectedLabels = HintLabelGenerator.labels(count: 6, alphabet: .vimiumDefault)
        #expect(Set(shown.placements.map(\.label)) == Set(expectedLabels))
        #expect(shown.appearance == Self.largeAppearance)
    }
}
