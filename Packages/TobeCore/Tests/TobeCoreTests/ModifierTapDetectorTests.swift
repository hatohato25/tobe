import Foundation
import Testing

@testable import TobeCore

/// テスト用の時刻。ミリ秒で書く
private func ms(_ milliseconds: UInt64) -> Timestamp {
    Timestamp(nanoseconds: milliseconds * 1_000_000)
}

private enum KeyCode {
    static let rightCommand: UInt16 = 0x36
    static let leftCommand: UInt16 = 0x37
    static let rightOption: UInt16 = 0x3D
    static let leftOption: UInt16 = 0x3A
    static let leftShift: UInt16 = 0x38
    static let capsLock: UInt16 = 0x39
    static let function: UInt16 = 0x3F
}

// 実機の flagsChanged と同じく、デバイス依存ビットと種類のビット（command / option）を両方立てる
private let rightCommandDown: ModifierFlags = [.command, .deviceRightCommand]
private let leftCommandDown: ModifierFlags = [.command, .deviceLeftCommand]
private let rightOptionDown: ModifierFlags = [.option, .deviceRightOption]

/// 右 ⌘ を `pressAt` に押し、`releaseAt` に離したときの [押下の結果, 解放の結果] を返す
private func tapRightCommand(
    _ detector: inout ModifierTapDetector,
    pressAt: UInt64,
    releaseAt: UInt64,
    extraFlags: ModifierFlags = []
) -> [TapDetection] {
    [
        detector.handle(
            .flagsChanged(
                keyCode: KeyCode.rightCommand,
                flags: rightCommandDown.union(extraFlags),
                at: ms(pressAt)
            )
        ),
        detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: extraFlags, at: ms(releaseAt))),
    ]
}

@Suite("ModifierTapDetector: 押してから離すまでの時間（F-1.1、F-1.2、暫定 Q-1）")
struct ModifierTapDetectorDurationTests {
    @Test("300ms 以内に離すと起動する", arguments: [0, 1, 150, 299] as [UInt64])
    func withinDuration(elapsed: UInt64) {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let results = tapRightCommand(&detector, pressAt: 1000, releaseAt: 1000 + elapsed)

        #expect(results == [.none, .tapped])
    }

    @Test("ちょうど 300ms は起動する（暫定 Q-1）")
    func exactlyMaxDuration() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let results = tapRightCommand(&detector, pressAt: 1000, releaseAt: 1300)

        #expect(results == [.none, .tapped])
    }

    @Test("300ms を 1ns でも超えると起動しない")
    func overMaxDurationByOneNanosecond() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        _ = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rightCommandDown, at: ms(1000)))
        let result = detector.handle(
            .flagsChanged(keyCode: KeyCode.rightCommand, flags: [], at: Timestamp(nanoseconds: 1_300_000_001))
        )

        #expect(result == .none)
    }

    @Test("300ms を超えると起動しない", arguments: [301, 500, 5000] as [UInt64])
    func overMaxDuration(elapsed: UInt64) {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let results = tapRightCommand(&detector, pressAt: 1000, releaseAt: 1000 + elapsed)

        #expect(results == [.none, .none])
    }

    @Test("長押しで起動しなかった後も、次のタップで起動する")
    func tapAfterLongPress() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        _ = tapRightCommand(&detector, pressAt: 0, releaseAt: 1000)
        let results = tapRightCommand(&detector, pressAt: 2000, releaseAt: 2100)

        #expect(results == [.none, .tapped])
    }

    @Test("上限の時間を指定できる")
    func customMaxDuration() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand, maxTapDuration: .milliseconds(100))

        #expect(tapRightCommand(&detector, pressAt: 0, releaseAt: 100) == [.none, .tapped])
        #expect(tapRightCommand(&detector, pressAt: 1000, releaseAt: 1101) == [.none, .none])
    }

    @Test("タップのたびに 1 回だけ起動を通知する（F-1.1）")
    func notifiesOncePerTap() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let first = tapRightCommand(&detector, pressAt: 0, releaseAt: 100)
        // 押していない状態で解放が重ねて届いても起動しない
        let duplicateRelease = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: [], at: ms(110)))
        let second = tapRightCommand(&detector, pressAt: 200, releaseAt: 300)

        #expect(first == [.none, .tapped])
        #expect(duplicateRelease == .none)
        #expect(second == [.none, .tapped])
    }

}

@Suite("ModifierTapDetector: 押下中の他の入力（F-1.3〜F-1.5、暫定 Q-2）")
struct ModifierTapDetectorInvalidationTests {
    @Test("押下中の keyDown（⌘C）で無効になる（F-1.3）")
    func invalidatedByKeyDown() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        _ = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rightCommandDown, at: ms(0)))
        let keyDown = detector.handle(.keyDown(at: ms(50)))
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: [], at: ms(100)))

        #expect(keyDown == .none)
        #expect(release == .none)
        // 無効化は離した時点で終わり、次のタップは起動する
        #expect(tapRightCommand(&detector, pressAt: 200, releaseAt: 300) == [.none, .tapped])
    }

    @Test("押下中のマウスボタンの押下（⌘ クリック）で無効になる（F-1.5）")
    func invalidatedByPointerDown() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        _ = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rightCommandDown, at: ms(0)))
        let pointerDown = detector.handle(.pointerDown(at: ms(50)))
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: [], at: ms(100)))

        #expect(pointerDown == .none)
        #expect(release == .none)
        #expect(tapRightCommand(&detector, pressAt: 200, releaseAt: 300) == [.none, .tapped])
    }

    struct OtherModifierCase: Sendable, CustomTestStringConvertible {
        let name: String
        let keyCode: UInt16
        let pressedFlags: ModifierFlags
        var testDescription: String { name }
    }

    @Test(
        "押下中に他の修飾キーを押すと無効になる（F-1.4）",
        arguments: [
            OtherModifierCase(name: "Shift", keyCode: KeyCode.leftShift, pressedFlags: [.shift]),
            OtherModifierCase(name: "左 ⌘", keyCode: KeyCode.leftCommand, pressedFlags: [.deviceLeftCommand]),
            OtherModifierCase(name: "左 ⌥", keyCode: KeyCode.leftOption, pressedFlags: [.option, .deviceLeftOption]),
            OtherModifierCase(name: "fn", keyCode: KeyCode.function, pressedFlags: [.secondaryFn]),
            OtherModifierCase(name: "Caps Lock", keyCode: KeyCode.capsLock, pressedFlags: [.alphaShift]),
        ]
    )
    func invalidatedByOtherModifierChange(_ testCase: OtherModifierCase) {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        _ = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rightCommandDown, at: ms(0)))
        let otherDown = detector.handle(
            .flagsChanged(keyCode: testCase.keyCode, flags: rightCommandDown.union(testCase.pressedFlags), at: ms(30))
        )
        let otherUp = detector.handle(.flagsChanged(keyCode: testCase.keyCode, flags: rightCommandDown, at: ms(60)))
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: [], at: ms(100)))

        #expect([otherDown, otherUp, release] == [.none, .none, .none])
        #expect(tapRightCommand(&detector, pressAt: 200, releaseAt: 300) == [.none, .tapped])
    }

    @Test(
        "押した時点で他の修飾キーが押されていると起動しない（F-1.4）",
        arguments: [
            ModifierFlags.shift, .control, .secondaryFn, .option, [.option, .deviceLeftOption],
            [.option, .deviceRightOption], .deviceLeftCommand,
        ]
    )
    func invalidatedByModifierHeldAtPress(held: ModifierFlags) {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let results = tapRightCommand(&detector, pressAt: 0, releaseAt: 100, extraFlags: held)

        #expect(results == [.none, .none])
    }

}

@Suite("ModifierTapDetector: 左右と起動キーの区別（F-1.6、D-5）")
struct ModifierTapDetectorKeyTests {
    @Test("左 ⌘ のタップでは起動しない（F-1.6）")
    func leftCommandTap() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let press = detector.handle(.flagsChanged(keyCode: KeyCode.leftCommand, flags: leftCommandDown, at: ms(0)))
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.leftCommand, flags: [], at: ms(100)))

        #expect([press, release] == [.none, .none])
        #expect(tapRightCommand(&detector, pressAt: 200, releaseAt: 300) == [.none, .tapped])
    }

    @Test("keyCode が右 ⌘ でも、デバイス依存ビットが左 ⌘ なら押下とみなさない（D-5）")
    func rightKeyCodeWithLeftDeviceBit() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let press = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: leftCommandDown, at: ms(0)))
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: [], at: ms(100)))

        #expect([press, release] == [.none, .none])
    }

    @Test("右 ⌘ が起動キーのとき、右 ⌥ のタップでは起動しない（F-1.6）")
    func rightOptionTapWhenTriggerIsRightCommand() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let press = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: rightOptionDown, at: ms(0)))
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: [], at: ms(100)))

        #expect([press, release] == [.none, .none])
    }

    @Test("左 ⌘ を押したまま右 ⌘ を離すと、command ビットが残っていても解放と判定する（D-5）")
    func releaseRightCommandWhileLeftCommandHeld() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        // 右 ⌘ → 左 ⌘ の順に押し、左 ⌘ を押したまま右 ⌘ を離す
        let rightDown = detector.handle(
            .flagsChanged(keyCode: KeyCode.rightCommand, flags: rightCommandDown, at: ms(0))
        )
        let leftDown = detector.handle(
            .flagsChanged(keyCode: KeyCode.leftCommand, flags: rightCommandDown.union(leftCommandDown), at: ms(30))
        )
        let rightUp = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: leftCommandDown, at: ms(60)))
        let leftUp = detector.handle(.flagsChanged(keyCode: KeyCode.leftCommand, flags: [], at: ms(90)))

        #expect([rightDown, leftDown, rightUp, leftUp] == [.none, .none, .none, .none])
        // 右 ⌘ の解放を取りこぼしていれば invalidated のままになり、次のタップが起動しない
        #expect(tapRightCommand(&detector, pressAt: 200, releaseAt: 300) == [.none, .tapped])
    }

    @Test("左 ⌘ を押したまま右 ⌘ をタップしても起動せず、その後の単独タップは起動する")
    func tapRightCommandWhileLeftCommandHeld() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        _ = detector.handle(.flagsChanged(keyCode: KeyCode.leftCommand, flags: leftCommandDown, at: ms(0)))
        let rightDown = detector.handle(
            .flagsChanged(keyCode: KeyCode.rightCommand, flags: rightCommandDown.union(leftCommandDown), at: ms(30))
        )
        let rightUp = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: leftCommandDown, at: ms(60)))
        _ = detector.handle(.flagsChanged(keyCode: KeyCode.leftCommand, flags: [], at: ms(90)))

        #expect([rightDown, rightUp] == [.none, .none])
        #expect(tapRightCommand(&detector, pressAt: 200, releaseAt: 300) == [.none, .tapped])
    }

}

@Suite("ModifierTapDetector: 右 ⌥ への切り替え（S-1）")
struct ModifierTapDetectorRightOptionTests {
    @Test("右 ⌥ を起動キーにすると、右 ⌥ のタップで起動し、右 ⌘ のタップでは起動しない")
    func rightOptionTrigger() {
        var detector = ModifierTapDetector(triggerKey: .rightOption)

        let optionPress = detector.handle(
            .flagsChanged(keyCode: KeyCode.rightOption, flags: rightOptionDown, at: ms(0))
        )
        let optionRelease = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: [], at: ms(100)))
        let commandTap = tapRightCommand(&detector, pressAt: 200, releaseAt: 300)

        #expect([optionPress, optionRelease] == [.none, .tapped])
        #expect(commandTap == [.none, .none])
    }

    @Test(
        "右 ⌥ が起動キーのとき、押した時点で他の修飾キーが押されていると起動しない",
        arguments: [
            ModifierFlags.shift, .control, .secondaryFn, .command, [.command, .deviceLeftCommand],
            [.command, .deviceRightCommand], .deviceLeftOption,
        ]
    )
    func rightOptionInvalidatedByModifierHeldAtPress(held: ModifierFlags) {
        var detector = ModifierTapDetector(triggerKey: .rightOption)

        let press = detector.handle(
            .flagsChanged(keyCode: KeyCode.rightOption, flags: rightOptionDown.union(held), at: ms(0))
        )
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: held, at: ms(100)))

        #expect([press, release] == [.none, .none])
    }

    @Test("右 ⌥ が起動キーのとき、左 ⌥ を押したまま右 ⌥ を離しても解放と判定する")
    func rightOptionReleaseWhileLeftOptionHeld() {
        var detector = ModifierTapDetector(triggerKey: .rightOption)
        let leftOptionDown: ModifierFlags = [.option, .deviceLeftOption]

        _ = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: rightOptionDown, at: ms(0)))
        _ = detector.handle(
            .flagsChanged(keyCode: KeyCode.leftOption, flags: rightOptionDown.union(leftOptionDown), at: ms(30))
        )
        let rightUp = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: leftOptionDown, at: ms(60)))
        _ = detector.handle(.flagsChanged(keyCode: KeyCode.leftOption, flags: [], at: ms(90)))

        #expect(rightUp == .none)
        let press = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: rightOptionDown, at: ms(200)))
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: [], at: ms(300)))
        #expect([press, release] == [.none, .tapped])
    }

    @Test("押下中に起動キーを切り替えると、判定の途中の状態を捨てる")
    func changingTriggerKeyResetsState() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        _ = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rightCommandDown, at: ms(0)))
        detector.triggerKey = .rightOption
        let oldRelease = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: [], at: ms(50)))
        let press = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: rightOptionDown, at: ms(100)))
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: [], at: ms(200)))

        #expect(detector.triggerKey == .rightOption)
        #expect([oldRelease, press, release] == [.none, .none, .tapped])
    }

}

@Suite("ModifierTapDetector: Caps Lock・reset()・押していないときの入力")
struct ModifierTapDetectorStateTests {
    @Test("Caps Lock がオン（alphaShift が立ったまま）でも起動する")
    func capsLockOn() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let results = tapRightCommand(&detector, pressAt: 0, releaseAt: 100, extraFlags: .alphaShift)

        #expect(results == [.none, .tapped])
    }

    @Test("Caps Lock がオンのとき、右 ⌥ でも起動する")
    func capsLockOnWithRightOption() {
        var detector = ModifierTapDetector(triggerKey: .rightOption)

        let press = detector.handle(
            .flagsChanged(keyCode: KeyCode.rightOption, flags: rightOptionDown.union(.alphaShift), at: ms(0))
        )
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightOption, flags: .alphaShift, at: ms(100)))

        #expect([press, release] == [.none, .tapped])
    }

    @Test("押下中に reset() すると、その後の解放では起動しない")
    func resetWhilePressed() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        _ = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rightCommandDown, at: ms(0)))
        detector.reset()
        let release = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: [], at: ms(100)))

        #expect(release == .none)
        #expect(tapRightCommand(&detector, pressAt: 200, releaseAt: 300) == [.none, .tapped])
    }

    @Test("無効化された状態で解放を取りこぼしても、reset() の後は単独タップで起動する")
    func resetWhileInvalidated() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        _ = detector.handle(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rightCommandDown, at: ms(0)))
        _ = detector.handle(.keyDown(at: ms(50)))
        // タップが OS に無効化され、右 ⌘ の解放が届かなかった想定（design.md 7.2）
        detector.reset()

        #expect(tapRightCommand(&detector, pressAt: 200, releaseAt: 300) == [.none, .tapped])
    }

    @Test("押していないときの keyDown・マウス・他の修飾キーは、次のタップに影響しない")
    func inputsWhileIdleAreIgnored() {
        var detector = ModifierTapDetector(triggerKey: .rightCommand)

        let results = [
            detector.handle(.keyDown(at: ms(0))),
            detector.handle(.pointerDown(at: ms(10))),
            detector.handle(.flagsChanged(keyCode: KeyCode.leftShift, flags: .shift, at: ms(20))),
            detector.handle(.flagsChanged(keyCode: KeyCode.leftShift, flags: [], at: ms(30))),
        ]

        #expect(results == [.none, .none, .none, .none])
        #expect(tapRightCommand(&detector, pressAt: 200, releaseAt: 300) == [.none, .tapped])
    }
}
