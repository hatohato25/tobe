import Testing

@testable import TobeCore

@Suite("HintModeMachine: selecting の文字入力（design.md 5.2、6.3）")
struct HintModeMachineSelectingCharacterTests {
    @Test("完全一致 → idle。hideHints → setKeySuppression(false) → perform の順（F-5.4）")
    func confirmPerformsAfterHiding() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        let target = try HintModeFixtures.hint(labeled: "d", in: machine)

        let effects = machine.send(.key(.character("d")))

        #expect(machine.state == .idle)
        #expect(effects == [.hideHints, .setKeySuppression(false), .perform(.leftClick, target.element)])
    }

    @Test("2 文字のラベルは、絞り込んだ後に完全一致で確定する")
    func confirmTwoCharacterLabel() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        let target = try HintModeFixtures.hint(labeled: "sd", in: machine)
        _ = machine.send(.key(.character("s")))

        let effects = machine.send(.key(.character("d")))

        #expect(machine.state == .idle)
        #expect(effects == [.hideHints, .setKeySuppression(false), .perform(.leftClick, target.element)])
    }

    @Test("候補が絞られる → selecting(typed + c)。残った候補の ID と入力済みの文字列で updateHints")
    func narrowUpdatesHints() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        let expected = try ["sa", "sd", "ss"].map { try HintModeFixtures.hint(labeled: $0, in: machine) }

        let effects = machine.send(.key(.character("s")))

        let context = try HintModeFixtures.selectionContext(of: machine)
        #expect(context.typed == "s")
        #expect(HintModeFixtures.ids(context.visibleHints) == HintModeFixtures.ids(expected))
        #expect(effects == [.updateHints(visible: HintModeFixtures.ids(expected), typed: "s")])
    }

    @Test("一致しない文字 → selecting のまま（typed も変えない）、エフェクトなし（Q-6）")
    func noMatchIsIgnored() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        _ = machine.send(.key(.character("s")))
        let before = machine.state

        // 文字セット外の文字と、文字セット内だが一致しない並び（"sf"）
        let outside = machine.send(.key(.character("z")))
        let unmatched = machine.send(.key(.character("f")))

        #expect(outside.isEmpty)
        #expect(unmatched.isEmpty)
        #expect(machine.state == before)
    }

    @Test("要素数 1: 表示しただけでは確定せず、1 文字入力して完全一致したときに確定する（design.md 6.3）")
    func singleElementNeedsInput() throws {
        let (initial, sessionID) = try HintModeFixtures.collecting()
        var machine = initial
        let result = HintModeFixtures.result(elementCount: 1)

        let shown = machine.send(.collectionSucceeded(sessionID, result))

        let context = try HintModeFixtures.selectionContext(of: machine)
        #expect(context.hints.map(\.label) == ["s"])
        #expect(shown == [.showHints(context.hints)])

        let confirmed = machine.send(.key(.character("s")))

        #expect(machine.state == .idle)
        #expect(confirmed == [.hideHints, .setKeySuppression(false), .perform(.leftClick, context.hints[0].element)])
    }

    @Test("確定の後は待機に戻り、次の triggerTapped で新しいセッションを始められる（F-5.5）")
    func canRestartAfterConfirm() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        let previous = try HintModeFixtures.selectionContext(of: machine).sessionID
        _ = machine.send(.key(.character("a")))

        let effects = machine.send(.triggerTapped(alphabet: .vimiumDefault))

        guard case .collecting(let context) = machine.state else {
            Issue.record("collecting ではない: \(machine.state)")
            return
        }
        #expect(context.sessionID != previous)
        #expect(effects == [.setKeySuppression(true), .startCollection(context.sessionID)])
    }
}

@Suite("HintModeMachine: selecting のその他の入力（design.md 5.2）")
struct HintModeMachineSelectingOtherTests {
    @Test("backspace（typed が空でない）→ 末尾を消した selecting。消した後の候補と文字列で updateHints（F-6.3）")
    func backspaceRestoresCandidates() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        let all = try HintModeFixtures.selectionContext(of: machine).hints
        _ = machine.send(.key(.character("s")))

        let effects = machine.send(.key(.backspace))

        let context = try HintModeFixtures.selectionContext(of: machine)
        #expect(context.typed.isEmpty)
        #expect(context.visibleHints == all)
        #expect(effects == [.updateHints(visible: HintModeFixtures.ids(all), typed: "")])
    }

    @Test("3 文字のラベル: 2 文字入力した後の backspace は、残った 1 文字を updateHints に載せる")
    func backspaceKeepsRemainingTyped() throws {
        // sadf・要素数 20 では 3 文字のラベルができる
        var machine = try HintModeFixtures.selecting(elementCount: 20, alphabet: try HintModeFixtures.sadf())
        let all = try HintModeFixtures.selectionContext(of: machine).hints
        let label = try #require(all.first { $0.label.count == 3 }?.label)
        let first = String(label.prefix(1))
        let firstTwo = String(label.prefix(2))
        _ = machine.send(.key(.character(Character(first))))

        let narrowed = machine.send(.key(.character(label[label.index(after: label.startIndex)])))
        let restored = machine.send(.key(.backspace))

        let narrowedHints = all.filter { $0.label.hasPrefix(firstTwo) }
        let restoredHints = all.filter { $0.label.hasPrefix(first) }
        #expect(narrowed == [.updateHints(visible: HintModeFixtures.ids(narrowedHints), typed: firstTwo)])
        #expect(restored == [.updateHints(visible: HintModeFixtures.ids(restoredHints), typed: first)])
    }

    @Test("backspace（typed が空）→ selecting のまま、エフェクトなし（Q-7）")
    func backspaceOnEmptyIsIgnored() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        let before = machine.state

        let effects = machine.send(.key(.backspace))

        #expect(effects.isEmpty)
        #expect(machine.state == before)
    }

    @Test("key(.escape) → idle。hideHints → setKeySuppression(false)。操作はしない（F-6.1）")
    func escapeHides() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        _ = machine.send(.key(.character("s")))

        let effects = machine.send(.key(.escape))

        #expect(machine.state == .idle)
        #expect(effects == [.hideHints, .setKeySuppression(false)])
    }

    @Test(
        "key(.ignored(_)) → selecting のまま、エフェクトなし（修飾キー付きの Backspace を含む。F-6.6）",
        arguments: [
            HintKeyInput.IgnoredReason.modifierCombination, .keyRepeat, .untranslatable, .nonLetterCharacter,
        ]
    )
    func ignoredKeys(reason: HintKeyInput.IgnoredReason) throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        _ = machine.send(.key(.character("s")))
        let before = machine.state

        let effects = machine.send(.key(.ignored(reason)))

        #expect(effects.isEmpty)
        #expect(machine.state == before)
    }

    @Test(
        "pointerDown / screensChanged → idle。hideHints → setKeySuppression(false)（Q-10）",
        arguments: [HintModeEvent.pointerDown, .screensChanged]
    )
    func pointerOrScreenChangeHides(event: HintModeEvent) throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())

        let effects = machine.send(event)

        #expect(machine.state == .idle)
        #expect(effects == [.hideHints, .setKeySuppression(false)])
    }

    @Test("triggerTapped → selecting のまま、エフェクトなし（Q-3）")
    func retriggerIsIgnored() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        let before = machine.state

        let effects = machine.send(.triggerTapped(alphabet: .vimiumDefault))

        #expect(effects.isEmpty)
        #expect(machine.state == before)
    }

    @Test("collectionSucceeded / Failed（古い結果。同じ id でも）→ selecting のまま、エフェクトなし")
    func lateResultsAreIgnored() throws {
        var machine = try HintModeFixtures.selecting(elementCount: 6, alphabet: try HintModeFixtures.sadf())
        let context = try HintModeFixtures.selectionContext(of: machine)
        let before = machine.state
        let older = SessionID(rawValue: context.sessionID.rawValue - 1)

        let results = [
            machine.send(.collectionSucceeded(context.sessionID, HintModeFixtures.result(elementCount: 3))),
            machine.send(.collectionSucceeded(older, HintModeFixtures.result(elementCount: 3))),
            machine.send(.collectionFailed(context.sessionID, .cancelled)),
            machine.send(.collectionFailed(older, .windowListUnavailable)),
        ]

        #expect(results.allSatisfy { $0.isEmpty })
        #expect(machine.state == before)
    }
}
