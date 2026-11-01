import Foundation
import Testing

@testable import TobiCore

@Suite("ラベルの文字セット（S-2）")
struct HintAlphabetTests {
    @Test("既定は sadfjklewcmpgh（S-2.1）")
    func vimiumDefault() throws {
        #expect(HintAlphabet.vimiumDefault.stringValue == "sadfjklewcmpgh")
        // 検証を通さずに作った既定値が、検証を通した値と等しい（不変条件を満たしている）こと
        #expect(HintAlphabet.vimiumDefault == (try HintAlphabet(validating: "sadfjklewcmpgh")))
    }

    @Test("正しい入力は並びを保って受け付ける", arguments: ["ab", "sadf", "zyx", "abcdefghijklmnopqrstuvwxyz"])
    func acceptsValidInput(input: String) throws {
        let alphabet = try HintAlphabet(validating: input)

        #expect(alphabet.characters == Array(input))
        #expect(alphabet.stringValue == input)
    }

    struct NormalizeCase: Sendable, CustomTestStringConvertible {
        let input: String
        let expected: String
        var testDescription: String { input }
    }

    @Test(
        "英大文字は小文字にそろえる（S-2.3）",
        arguments: [
            NormalizeCase(input: "SADF", expected: "sadf"),
            NormalizeCase(input: "SaDf", expected: "sadf"),
            NormalizeCase(input: "ABCDEFGHIJKLMNOPQRSTUVWXYZ", expected: "abcdefghijklmnopqrstuvwxyz"),
        ]
    )
    func lowercasesUppercase(_ testCase: NormalizeCase) throws {
        let alphabet = try HintAlphabet(validating: testCase.input)

        #expect(alphabet.stringValue == testCase.expected)
        #expect(alphabet == (try HintAlphabet(validating: testCase.expected)))
    }

    struct RejectCase: Sendable, CustomTestStringConvertible {
        let input: String
        let error: HintAlphabetError
        var testDescription: String { input.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ") }
    }

    @Test(
        "不正な入力は型付きエラーで拒否する（S-2.2、暫定 Q-20）",
        arguments: [
            RejectCase(input: "", error: .tooFewCharacters(count: 0)),
            RejectCase(input: "a", error: .tooFewCharacters(count: 1)),
            RejectCase(input: "Z", error: .tooFewCharacters(count: 1)),
            RejectCase(input: "aa", error: .duplicateCharacter("a")),
            RejectCase(input: "sadfs", error: .duplicateCharacter("s")),
            // 小文字にそろえた後で重複になる
            RejectCase(input: "aA", error: .duplicateCharacter("a")),
            RejectCase(input: "ab1", error: .unsupportedCharacter("1")),
            RejectCase(input: "a b", error: .unsupportedCharacter(" ")),
            RejectCase(input: "ab;", error: .unsupportedCharacter(";")),
            RejectCase(input: "abé", error: .unsupportedCharacter("é")),
            RejectCase(input: "abあ", error: .unsupportedCharacter("あ")),
            // 全角英字は a-z ではない
            RejectCase(input: "abｃ", error: .unsupportedCharacter("ｃ")),
            // ケルビン記号（U+212A）は Unicode の小文字化で "k" になるが、a-z ではないので拒否する
            RejectCase(input: "ab\u{212A}", error: .unsupportedCharacter("\u{212A}")),
            // 結合文字付きの "e" は 1 文字（Character）だが、a-z ではない
            RejectCase(input: "abe\u{0301}", error: .unsupportedCharacter("e\u{0301}")),
            // 使えない文字の検査は、重複・文字数より先に行う
            RejectCase(input: "1", error: .unsupportedCharacter("1")),
            RejectCase(input: "aa1", error: .duplicateCharacter("a")),
            RejectCase(input: "a1a", error: .unsupportedCharacter("1")),
        ]
    )
    func rejectsInvalidInput(_ testCase: RejectCase) {
        #expect(throws: testCase.error) {
            try HintAlphabet(validating: testCase.input)
        }
    }
}
