import Foundation
import Testing

@testable import TobiCore

@Suite("キー破棄の記録（design.md 7.3、F-7.1〜F-7.3）")
struct KeySuppressionTrackerTests {
    private let keyA: UInt16 = 0x00
    private let keyS: UInt16 = 0x01
    private let rightCommand: UInt16 = 0x36

    @Test("keyDown・isSuppressing: 破棄し、対応する keyUp も破棄する")
    func keyDownWhileSuppressing() {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: true) == .suppress)
        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: true) == .suppress)
    }

    @Test("keyDown・!isSuppressing: そのまま渡し、keyUp も渡す")
    func keyDownWhileNotSuppressing() {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: false) == .pass)
        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: false) == .pass)
    }

    @Test("keyUp・記録にある: ヒントモードの終了後に届いても破棄する（F-7.1）")
    func keyUpAfterHintModeEnded() {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: true) == .suppress)
        // 確定に使ったキーの keyUp は、ヒントモードが終わった後（isSuppressing == false）に届く
        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: false) == .suppress)
    }

    @Test("keyUp・記録にある: 記録から消すので、次の keyUp は渡す")
    func keyUpRemovesRecord() {
        var tracker = KeySuppressionTracker()

        _ = tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: true)
        _ = tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: false)

        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: false) == .pass)
        #expect(tracker == KeySuppressionTracker())
    }

    @Test("keyUp・記録にない: ヒントモードの前から押されていたキーの keyUp は渡す（F-7.2）")
    func keyUpOfKeyPressedBeforeHintMode() {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: false) == .pass)
        // ここでヒントモードが始まる
        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: true) == .pass)
    }

    @Test("keyUp・記録にない: タップの開始前から押されていたキー（keyDown を見ていない）の keyUp は渡す")
    func keyUpWithoutAnyKeyDown() {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: true) == .pass)
    }

    @Test("flagsChanged: ヒントモード中でも常に渡し、記録しない（F-7.3）", arguments: [true, false])
    func flagsChangedAlwaysPasses(isSuppressing: Bool) {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .flagsChanged, keyCode: rightCommand, isSuppressing: isSuppressing) == .pass)
        #expect(tracker == KeySuppressionTracker())
        // 同じ keyCode の keyUp が来ても、記録がないので渡す
        #expect(tracker.disposition(for: .keyUp, keyCode: rightCommand, isSuppressing: isSuppressing) == .pass)
    }

    @Test("キーごとに記録する: 破棄したキーと渡したキーが混ざっても取り違えない")
    func tracksEachKeyCodeSeparately() {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .keyDown, keyCode: keyS, isSuppressing: false) == .pass)
        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: true) == .suppress)
        #expect(tracker.disposition(for: .keyUp, keyCode: keyS, isSuppressing: false) == .pass)
        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: false) == .suppress)
    }

    @Test("ヒントモード中のリピートも破棄し、keyUp は 1 回だけ破棄する")
    func repeatedKeyDownWhileSuppressing() {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: true) == .suppress)
        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: true) == .suppress)
        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: true) == .suppress)
        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: true) == .pass)
    }

    @Test("前から押されていたキーのリピートはヒントモード中は破棄するが、keyUp はアプリに渡す（F-7.2）")
    func repeatOfKeyPressedBeforeHintMode() {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: false) == .pass)
        // ヒントモードが始まり、押しっぱなしのキーのリピートが届く
        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: true) == .suppress)
        // アプリは最初の keyDown を受け取っているので、keyUp を渡さないとキーが押されたままになる
        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: true) == .pass)
    }

    @Test("keyUp を取りこぼして記録が残っても、次にアプリへ渡したキーの keyUp は破棄しない")
    func passedKeyDownClearsStaleRecord() {
        var tracker = KeySuppressionTracker()

        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: true) == .suppress)
        // タップが無効の間に keyUp が届かず、記録が残ったままヒントモードが終わる
        #expect(tracker.disposition(for: .keyDown, keyCode: keyA, isSuppressing: false) == .pass)
        #expect(tracker.disposition(for: .keyUp, keyCode: keyA, isSuppressing: false) == .pass)
    }
}
