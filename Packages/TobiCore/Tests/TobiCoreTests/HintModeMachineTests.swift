import CoreGraphics
import Testing

@testable import TobiCore

/// `HintModeMachine` のテストで共有する入力と、状態を進める手順。
enum HintModeFixtures {
    static let windowID = WindowID(rawValue: 1)

    /// 互いに重ならない `count` 個の要素を持つ収集結果（1 行 10 個、20pt 間隔）。
    static func result(elementCount count: Int) -> CollectionResult {
        let window = WindowInfo(
            id: windowID,
            ownerPID: ProcessID(rawValue: 100),
            frame: GlobalRect(rect: CGRect(x: 0, y: 0, width: 2000, height: 2000)),
            layer: 0,
            zIndex: 0
        )
        let elements = (0..<count).map { index in
            CollectedElement(
                id: ElementID(rawValue: index + 1),
                windowID: windowID,
                frame: GlobalRect(
                    rect: CGRect(x: CGFloat(index % 10) * 20, y: CGFloat(index / 10) * 20, width: 10, height: 10)
                ),
                role: "AXButton"
            )
        }
        return CollectionResult(windows: [window], elements: elements, diagnostics: [])
    }

    /// `sadf`。要素数 6 で `a, sa, d, sd, f, ss`（design.md 6.2）になり、2 文字のラベルを試せる。
    static func sadf() throws -> HintAlphabet {
        try HintAlphabet(validating: "sadf")
    }

    /// 起動して収集中にしたマシンと、そのセッションの ID。
    static func collecting(alphabet: HintAlphabet = .vimiumDefault) throws -> (HintModeMachine, SessionID) {
        var machine = HintModeMachine()
        _ = machine.send(.triggerTapped(alphabet: alphabet))
        guard case .collecting(let context) = machine.state else {
            Issue.record("triggerTapped の後が collecting ではない: \(machine.state)")
            throw FixtureError.unexpectedState
        }
        return (machine, context.sessionID)
    }

    /// `elementCount` 個の要素でラベル入力中にしたマシン。
    static func selecting(
        elementCount: Int,
        alphabet: HintAlphabet = .vimiumDefault
    ) throws -> HintModeMachine {
        var (machine, sessionID) = try collecting(alphabet: alphabet)
        _ = machine.send(.collectionSucceeded(sessionID, result(elementCount: elementCount)))
        guard case .selecting = machine.state else {
            Issue.record("collectionSucceeded の後が selecting ではない: \(machine.state)")
            throw FixtureError.unexpectedState
        }
        return machine
    }

    static func selectionContext(of machine: HintModeMachine) throws -> SelectionContext {
        guard case .selecting(let context) = machine.state else {
            Issue.record("selecting ではない: \(machine.state)")
            throw FixtureError.unexpectedState
        }
        return context
    }

    static func hint(labeled label: String, in machine: HintModeMachine) throws -> Hint {
        let context = try selectionContext(of: machine)
        guard let hint = context.hints.first(where: { $0.label == label }) else {
            Issue.record("ラベル \(label) のヒントがない: \(context.hints.map(\.label))")
            throw FixtureError.missingHint
        }
        return hint
    }

    static func ids(_ hints: [Hint]) -> Set<ElementID> {
        Set(hints.map(\.element.id))
    }

    /// Esc 以外のキー入力。収集中はどれも無視する（暫定 Q-4）。
    static let keyInputs: [HintKeyInput] = [
        .character("a"),
        .backspace,
        .ignored(.modifierCombination),
        .ignored(.keyRepeat),
        .ignored(.untranslatable),
        .ignored(.nonLetterCharacter),
    ]

    enum FixtureError: Error {
        case unexpectedState
        case missingHint
    }
}

@Suite("HintModeMachine: idle（design.md 5.2）")
struct HintModeMachineIdleTests {
    @Test("初期状態は idle")
    func initialState() {
        #expect(HintModeMachine().state == .idle)
    }

    @Test("idle + triggerTapped → collecting。キー破棄を ON にしてから収集を始める")
    func triggerStartsCollection() throws {
        let alphabet = try HintModeFixtures.sadf()
        var machine = HintModeMachine()

        let effects = machine.send(.triggerTapped(alphabet: alphabet))

        guard case .collecting(let context) = machine.state else {
            Issue.record("collecting ではない: \(machine.state)")
            return
        }
        #expect(context.alphabet == alphabet)
        #expect(effects == [.setKeySuppression(true), .startCollection(context.sessionID)])
    }

    @Test(
        "idle + その他のイベント → idle、エフェクトなし",
        arguments: [
            HintModeEvent.key(.escape),
            .key(.character("a")),
            .key(.backspace),
            .key(.ignored(.modifierCombination)),
            .pointerDown,
            .screensChanged,
            .collectionSucceeded(SessionID(rawValue: 1), HintModeFixtures.result(elementCount: 3)),
            .collectionFailed(SessionID(rawValue: 1), .accessibilityNotTrusted),
        ]
    )
    func otherEventsAreIgnored(event: HintModeEvent) {
        var machine = HintModeMachine()

        let effects = machine.send(event)

        #expect(effects.isEmpty)
        #expect(machine.state == .idle)
    }

    @Test("SessionID はセッションごとに単調に増える")
    func sessionIDIncreases() throws {
        var (machine, first) = try HintModeFixtures.collecting()
        _ = machine.send(.key(.escape))
        _ = machine.send(.triggerTapped(alphabet: .vimiumDefault))
        guard case .collecting(let second) = machine.state else {
            Issue.record("collecting ではない: \(machine.state)")
            return
        }
        _ = machine.send(.collectionFailed(second.sessionID, .windowListUnavailable))
        _ = machine.send(.triggerTapped(alphabet: .vimiumDefault))
        guard case .collecting(let third) = machine.state else {
            Issue.record("collecting ではない: \(machine.state)")
            return
        }

        #expect(first.rawValue < second.sessionID.rawValue)
        #expect(second.sessionID.rawValue < third.sessionID.rawValue)
    }
}

@Suite("HintModeMachine: collecting（design.md 5.2）")
struct HintModeMachineCollectingTests {
    @Test("collectionSucceeded（1 件以上）→ selecting(id, hints, \"\")。showHints だけを出す")
    func successShowsHints() throws {
        var (machine, sessionID) = try HintModeFixtures.collecting()
        let result = HintModeFixtures.result(elementCount: 3)
        let expected = HintPipeline.makeHints(from: result, alphabet: .vimiumDefault)

        let effects = machine.send(.collectionSucceeded(sessionID, result))

        let context = try HintModeFixtures.selectionContext(of: machine)
        #expect(context.sessionID == sessionID)
        #expect(context.hints == expected.hints)
        #expect(context.typed.isEmpty)
        #expect(context.visibleHints == expected.hints)
        #expect(effects == [.showHints(expected.hints)])
    }

    @Test("ラベルはセッション開始時の文字セットで作る（S-0.4）")
    func usesSessionAlphabet() throws {
        let alphabet = try HintModeFixtures.sadf()
        let machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: alphabet)

        let context = try HintModeFixtures.selectionContext(of: machine)
        #expect(context.hints.map(\.label).sorted() == ["a", "d", "f", "sa", "sd", "ss"])
    }

    @Test("collectionSucceeded（0 件）→ idle。キー破棄を解いてから失敗の音（Q-11）")
    func emptyResultPlaysFailure() throws {
        var (machine, sessionID) = try HintModeFixtures.collecting()

        let effects = machine.send(.collectionSucceeded(sessionID, HintModeFixtures.result(elementCount: 0)))

        #expect(machine.state == .idle)
        #expect(effects == [.setKeySuppression(false), .playFailure])
    }

    @Test("遮蔽の除外で 0 件になった場合も 0 件として扱う（判定は HintPipeline の結果の hints.isEmpty）")
    func allElementsFilteredOut() throws {
        var (machine, sessionID) = try HintModeFixtures.collecting()
        let source = HintModeFixtures.result(elementCount: 3)
        // ウィンドウの一覧にないウィンドウの要素は OcclusionFilter が除く
        let result = CollectionResult(windows: [], elements: source.elements, diagnostics: [])

        let effects = machine.send(.collectionSucceeded(sessionID, result))

        #expect(machine.state == .idle)
        #expect(effects == [.setKeySuppression(false), .playFailure])
    }

    @Test(
        "collectionFailed → idle。キー破棄を解いてから失敗の音",
        arguments: [CollectionError.accessibilityNotTrusted, .windowListUnavailable, .cancelled]
    )
    func failurePlaysFailure(error: CollectionError) throws {
        var (machine, sessionID) = try HintModeFixtures.collecting()

        let effects = machine.send(.collectionFailed(sessionID, error))

        #expect(machine.state == .idle)
        #expect(effects == [.setKeySuppression(false), .playFailure])
    }

    @Test("別の id の collectionSucceeded / Failed は捨てる（collecting のまま、エフェクトなし）")
    func staleResultsAreDropped() throws {
        var (machine, sessionID) = try HintModeFixtures.collecting()
        let before = machine.state
        let stale = SessionID(rawValue: sessionID.rawValue + 1)

        let succeeded = machine.send(.collectionSucceeded(stale, HintModeFixtures.result(elementCount: 3)))
        let failed = machine.send(.collectionFailed(stale, .windowListUnavailable))

        #expect(succeeded.isEmpty)
        #expect(failed.isEmpty)
        #expect(machine.state == before)
    }

    @Test("key(.escape) → idle。収集をやめてからキー破棄を解く（F-6.2）")
    func escapeCancelsCollection() throws {
        var (machine, sessionID) = try HintModeFixtures.collecting()

        let effects = machine.send(.key(.escape))

        #expect(machine.state == .idle)
        #expect(effects == [.cancelCollection(sessionID), .setKeySuppression(false)])
    }

    @Test("Esc の後に届いた古い収集結果は捨て、次のセッションにも混ざらない（F-6.2）")
    func resultAfterEscapeIsDropped() throws {
        var (machine, oldID) = try HintModeFixtures.collecting()
        _ = machine.send(.key(.escape))

        // 待機中に届いた古い結果
        #expect(machine.send(.collectionSucceeded(oldID, HintModeFixtures.result(elementCount: 3))).isEmpty)
        #expect(machine.state == .idle)

        // 次のセッションの収集中に届いた古い結果
        _ = machine.send(.triggerTapped(alphabet: .vimiumDefault))
        let collecting = machine.state
        #expect(machine.send(.collectionSucceeded(oldID, HintModeFixtures.result(elementCount: 3))).isEmpty)
        #expect(machine.send(.collectionFailed(oldID, .cancelled)).isEmpty)
        #expect(machine.state == collecting)
    }

    @Test("key(Esc 以外) → collecting のまま、エフェクトなし（Q-4）", arguments: HintModeFixtures.keyInputs)
    func otherKeysAreIgnored(input: HintKeyInput) throws {
        var (machine, _) = try HintModeFixtures.collecting()
        let before = machine.state

        let effects = machine.send(.key(input))

        #expect(effects.isEmpty)
        #expect(machine.state == before)
    }

    @Test(
        "pointerDown / screensChanged → idle。収集をやめてからキー破棄を解く（Q-10）",
        arguments: [HintModeEvent.pointerDown, .screensChanged]
    )
    func pointerOrScreenChangeCancels(event: HintModeEvent) throws {
        var (machine, sessionID) = try HintModeFixtures.collecting()

        let effects = machine.send(event)

        #expect(machine.state == .idle)
        #expect(effects == [.cancelCollection(sessionID), .setKeySuppression(false)])
    }

    @Test("triggerTapped → collecting のまま、エフェクトなし（Q-3）")
    func retriggerIsIgnored() throws {
        var (machine, _) = try HintModeFixtures.collecting()
        let before = machine.state

        let effects = machine.send(.triggerTapped(alphabet: try HintModeFixtures.sadf()))

        #expect(effects.isEmpty)
        #expect(machine.state == before)
    }
}

@Suite("HintModeMachine: 件数の上限による切り捨て（design.md 3.6、T25）")
struct HintModeMachineTruncationTests {
    @Test("切り捨てがあれば、showHints の直前に件数を報告する")
    func reportsTruncation() throws {
        var (machine, sessionID) = try HintModeFixtures.collecting()
        let result = HintModeFixtures.result(elementCount: HintPipeline.maxHints + 7)
        let expected = HintPipeline.makeHints(from: result, alphabet: .vimiumDefault)

        let effects = machine.send(.collectionSucceeded(sessionID, result))

        #expect(expected.truncatedCount == 7)
        #expect(effects == [.reportTruncatedHints(count: 7), .showHints(expected.hints)])
        #expect(try HintModeFixtures.selectionContext(of: machine).hints.count == HintPipeline.maxHints)
    }

    @Test("上限ちょうどなら報告しない")
    func noReportAtLimit() throws {
        var (machine, sessionID) = try HintModeFixtures.collecting()

        let effects = machine.send(
            .collectionSucceeded(sessionID, HintModeFixtures.result(elementCount: HintPipeline.maxHints))
        )

        #expect(effects.count == 1)
        #expect(!effects.contains { if case .reportTruncatedHints = $0 { true } else { false } })
    }
}
