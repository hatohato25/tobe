import Foundation
import Testing

@testable import TobiCore

@Suite("キー入力の分類（design.md 3.4、7.6、F-4.5、F-4.6）")
struct HintKeyInputTests {
    private let keyA: UInt16 = 0x00
    private let escape: UInt16 = 0x35
    private let backspace: UInt16 = 0x33

    @Test("Esc（0x35）は keyCode で判定する。変換結果に依存しない", arguments: [nil, Character("\u{1B}"), Character("a")])
    func escape(translated: Character?) {
        #expect(HintKeyInput.classify(keyCode: escape, translated: translated, flags: [], isRepeat: false) == .escape)
    }

    @Test("Backspace（0x33）は keyCode で判定する。変換結果に依存しない", arguments: [nil, Character("\u{08}"), Character("a")])
    func backspace(translated: Character?) {
        #expect(
            HintKeyInput.classify(keyCode: backspace, translated: translated, flags: [], isRepeat: false) == .backspace
        )
    }

    @Test("英小文字はそのまま文字として扱う", arguments: Array("abcdefghijklmnopqrstuvwxyz"))
    func lowercaseLetter(character: Character) {
        #expect(
            HintKeyInput.classify(keyCode: keyA, translated: character, flags: [], isRepeat: false)
                == .character(character)
        )
    }

    struct UppercaseCase: Sendable, CustomTestStringConvertible {
        let translated: Character
        let expected: Character
        var testDescription: String { String(translated) }
    }

    @Test(
        "英大文字は小文字にそろえる（F-4.5）",
        arguments: zip(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), Array("abcdefghijklmnopqrstuvwxyz")).map {
            UppercaseCase(translated: $0, expected: $1)
        }
    )
    func uppercaseLetter(_ testCase: UppercaseCase) {
        #expect(
            HintKeyInput.classify(keyCode: keyA, translated: testCase.translated, flags: [], isRepeat: false)
                == .character(testCase.expected)
        )
    }

    @Test("Shift と Caps Lock と Fn は無視する（F-4.5）", arguments: [ModifierFlags.shift, .alphaShift, .secondaryFn])
    func ignoresShiftLikeModifiers(flags: ModifierFlags) {
        #expect(HintKeyInput.classify(keyCode: keyA, translated: "a", flags: flags, isRepeat: false) == .character("a"))
        #expect(HintKeyInput.classify(keyCode: keyA, translated: "A", flags: flags, isRepeat: false) == .character("a"))
    }

    @Test(
        "⌘ / ⌃ / ⌥ 付きはラベル入力として扱わない（F-4.5、暫定 Q-8）",
        arguments: [
            ModifierFlags.command,
            .control,
            .option,
            [.command, .deviceLeftCommand],
            [.option, .deviceRightOption],
            [.shift, .command],
        ]
    )
    func ignoresCommandControlOption(flags: ModifierFlags) {
        #expect(
            HintKeyInput.classify(keyCode: keyA, translated: "a", flags: flags, isRepeat: false)
                == .ignored(.modifierCombination)
        )
    }

    @Test(
        "⌘ / ⌃ / ⌥ 付きでも Esc は Esc として扱う（修飾キーを押したままでも終了できる）",
        arguments: [ModifierFlags.command, .control, .option, [.command, .shift], [.control, .option]]
    )
    func modifiedEscapeStillEscapes(flags: ModifierFlags) {
        #expect(HintKeyInput.classify(keyCode: escape, translated: nil, flags: flags, isRepeat: false) == .escape)
    }

    @Test("⌘ / ⌃ / ⌥ 付きの Backspace は扱わない", arguments: [ModifierFlags.command, .control, .option])
    func ignoresModifiedBackspace(flags: ModifierFlags) {
        #expect(
            HintKeyInput.classify(keyCode: backspace, translated: nil, flags: flags, isRepeat: false)
                == .ignored(.modifierCombination)
        )
    }

    @Test("デバイス依存ビットだけ（command ビットなし）では無視しない")
    func deviceFlagsAloneDoNotBlock() {
        let flags: ModifierFlags = [.deviceLeftCommand, .deviceRightOption]

        #expect(HintKeyInput.classify(keyCode: keyA, translated: "a", flags: flags, isRepeat: false) == .character("a"))
    }

    @Test("キーリピートは文字・Esc・Backspace のどれでも扱わない（F-4.6、暫定 Q-29）")
    func ignoresRepeat() {
        #expect(
            HintKeyInput.classify(keyCode: keyA, translated: "a", flags: [], isRepeat: true)
                == .ignored(.keyRepeat)
        )
        #expect(
            HintKeyInput.classify(keyCode: escape, translated: nil, flags: [], isRepeat: true)
                == .ignored(.keyRepeat)
        )
        #expect(
            HintKeyInput.classify(keyCode: backspace, translated: nil, flags: [], isRepeat: true)
                == .ignored(.keyRepeat)
        )
    }

    @Test("リピートは修飾キーより先に判定する")
    func repeatTakesPrecedenceOverModifiers() {
        #expect(
            HintKeyInput.classify(keyCode: keyA, translated: "a", flags: .command, isRepeat: true)
                == .ignored(.keyRepeat)
        )
    }

    @Test("変換できないキーは理由を付けて明示する（JIS の英数 0x66・かな 0x68、矢印 0x7B）", arguments: [UInt16(0x66), 0x68, 0x7B])
    func untranslatableKey(keyCode: UInt16) {
        #expect(
            HintKeyInput.classify(keyCode: keyCode, translated: nil, flags: [], isRepeat: false)
                == .ignored(.untranslatable)
        )
    }

    @Test(
        "英字以外の文字は扱わない（ラベルは a-z だけ。D-21）",
        arguments: [
            Character("1"), ";", " ", "-", "é", "あ",
            "\u{212A}",  // ケルビン記号。Unicode の小文字化では k になるが、受け付けない
            "\u{0130}",  // ドット付きの I。Unicode の小文字化では i + 結合文字になる
            "e\u{0301}",  // 結合文字を含む書記素クラスタ
        ]
    )
    func nonLetterCharacter(translated: Character) {
        #expect(
            HintKeyInput.classify(keyCode: keyA, translated: translated, flags: [], isRepeat: false)
                == .ignored(.nonLetterCharacter)
        )
    }
}
