import CoreGraphics
import Testing

@testable import TobeCore

private func element(_ id: Int) -> CollectedElement {
    CollectedElement(
        id: ElementID(rawValue: id),
        windowID: WindowID(rawValue: 1),
        frame: GlobalRect(rect: CGRect(x: Double(id), y: 0, width: 10, height: 10)),
        role: "AXButton"
    )
}

/// ラベル列からヒント列を作る。i 番目のラベルを ElementID i の要素に割り当てる。
private func hints(_ labels: [String]) -> [Hint] {
    labels.enumerated().map { index, label in Hint(label: label, element: element(index)) }
}

private func hints(count: Int, alphabet: HintAlphabet) -> [Hint] {
    hints(HintLabelGenerator.labels(count: count, alphabet: alphabet))
}

@Suite("Hint")
struct HintTests {
    @Test("ラベルは小文字で保持する（Q-8）")
    func labelIsLowercased() {
        #expect(Hint(label: "SA", element: element(0)).label == "sa")
        #expect(Hint(label: "sa", element: element(0)).label == "sa")
    }
}

@Suite("LabelFilter.match（F-4.1、F-4.2、F-4.5）")
struct LabelFilterTests {
    // sadf × 6 → a, sa, d, sd, f, ss（spec.md 4.5）
    static let sample = hints(["a", "sa", "d", "sd", "f", "ss"])

    @Test("完全一致で confirmed（F-4.2）", arguments: ["a", "sa", "d", "sd", "f", "ss"])
    func confirmed(typed: String) throws {
        let expected = try #require(Self.sample.first { $0.label == typed })

        #expect(LabelFilter.match(typed, in: Self.sample) == .confirmed(expected))
    }

    @Test("接頭辞が一致する候補だけを元の順序で返す（F-4.1）")
    func narrowed() {
        let result = LabelFilter.match("s", in: Self.sample)

        #expect(result == .narrowed([Self.sample[1], Self.sample[3], Self.sample[5]]))
    }

    @Test("一致するラベルがなければ noMatch（F-4.4）", arguments: ["j", "aa", "sf", "ssa", "1", " "])
    func noMatch(typed: String) {
        #expect(LabelFilter.match(typed, in: Self.sample) == .noMatch)
    }

    @Test("大文字と小文字を区別しない（F-4.5）")
    func caseInsensitive() {
        #expect(LabelFilter.match("SA", in: Self.sample) == .confirmed(Self.sample[1]))
        #expect(LabelFilter.match("Sd", in: Self.sample) == .confirmed(Self.sample[3]))
        #expect(LabelFilter.match("S", in: Self.sample) == LabelFilter.match("s", in: Self.sample))
    }

    @Test("大文字で作ったヒントも小文字の入力に一致する")
    func uppercaseHintLabel() {
        let upper = hints(["A", "SA", "SS"])

        #expect(LabelFilter.match("sa", in: upper) == .confirmed(upper[1]))
    }

    @Test("入力が空なら全件が候補（入力前の初期状態）")
    func emptyInput() {
        #expect(LabelFilter.match("", in: Self.sample) == .narrowed(Self.sample))
    }

    @Test("ヒントが空なら常に noMatch", arguments: ["", "a", "sa"])
    func emptyHints(typed: String) {
        #expect(LabelFilter.match(typed, in: []) == .noMatch)
    }

    @Test("ヒントが 1 件: ラベルの入力で confirmed、空の入力では候補 1 件の narrowed")
    func singleHint() {
        let single = hints(count: 1, alphabet: .vimiumDefault)

        #expect(single.map(\.label) == ["s"])
        #expect(LabelFilter.match("s", in: single) == .confirmed(single[0]))
        #expect(LabelFilter.match("", in: single) == .narrowed(single))
        #expect(LabelFilter.match("a", in: single) == .noMatch)
    }
}

@Suite("LabelFilter の性質: 候補が 1 件 ⇔ 完全一致（F-4.3、Q-5、design.md 6.3）")
struct LabelFilterPropertyTests {
    struct PropertyCase: Sendable, CustomTestStringConvertible {
        let alphabet: String
        let count: Int
        var testDescription: String { "\(alphabet) × \(count)" }
    }

    static let alphabets = ["ab", "abc", "sadf", "sadfjklewcmpgh", "abcdefghijklmnopqrstuvwxyz"]
    // 1 段目が埋まる直前・直後（文字セットの長さ ±1）や 2 段目が埋まる付近を含む代表値
    static let counts = [1, 2, 3, 4, 5, 6, 13, 14, 15, 16, 25, 26, 27, 100, 195, 196, 197, 500, 677, 999, 1000]
    static let cases = alphabets.flatMap { alphabet in
        counts.map { PropertyCase(alphabet: alphabet, count: $0) }
    }

    /// 空でない入力として、ラベルの真の接頭辞・ラベルそのもの・一致しない文字列をすべて試す。
    /// 入力が空の場合は、入力前の初期状態にあたるため対象外（`LabelFilterTests.singleHint`）。
    @Test("空でない入力で、候補が 1 件になるのは完全一致のときだけ", arguments: cases)
    func singleCandidateIffExactMatch(_ testCase: PropertyCase) throws {
        let alphabet = try HintAlphabet(validating: testCase.alphabet)
        let hints = hints(count: testCase.count, alphabet: alphabet)
        let labels = Set(hints.map(\.label))
        var inputs = Set<String>()
        for label in labels {
            for length in 1...label.count {
                inputs.insert(String(label.prefix(length)))
            }
            // 末尾に文字を足すと、ラベルは互いに接頭辞にならないので一致しなくなる
            inputs.insert(label + String(alphabet.characters[0]))
        }

        for typed in inputs {
            let result = LabelFilter.match(typed, in: hints)
            let candidateCount = hints.filter { $0.label.hasPrefix(typed) }.count
            switch result {
            case .confirmed(let hint):
                #expect(hint.label == typed)
                #expect(candidateCount == 1)
            case .narrowed(let candidates):
                #expect(!labels.contains(typed))
                #expect(candidates.count == candidateCount)
                #expect(candidates.count >= 2, "候補 1 件で完全一致していない: \(typed)")
            case .noMatch:
                #expect(candidateCount == 0)
            }
            // 大文字の入力でも同じ結果になる（F-4.5）
            #expect(LabelFilter.match(typed.uppercased(), in: hints) == result)
        }
    }
}
