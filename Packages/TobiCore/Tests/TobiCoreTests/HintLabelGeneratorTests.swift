import Foundation
import Testing

@testable import TobiCore

private func alphabet(_ string: String) throws -> HintAlphabet {
    try HintAlphabet(validating: string)
}

@Suite("ラベル生成（spec.md 4.5、design.md 6）")
struct HintLabelGeneratorTests {
    @Test("必須: 文字セット sadf・要素数 6 → a, sa, d, sd, f, ss（F-3.1）")
    func specExample() throws {
        let labels = HintLabelGenerator.labels(count: 6, alphabet: try alphabet("sadf"))

        #expect(labels == ["a", "sa", "d", "sd", "f", "ss"])
    }

    struct TableCase: Sendable, CustomTestStringConvertible {
        let alphabet: String
        let count: Int
        let expected: [String]
        var testDescription: String { "\(alphabet) × \(count)" }
    }

    @Test(
        "design.md 6.2 の表（F-3.2）",
        arguments: [
            TableCase(alphabet: "sadf", count: 6, expected: ["a", "sa", "d", "sd", "f", "ss"]),
            TableCase(alphabet: "sadf", count: 4, expected: ["a", "d", "f", "s"]),
            TableCase(alphabet: "sadf", count: 5, expected: ["a", "sa", "d", "f", "ss"]),
            TableCase(alphabet: "sadfjklewcmpgh", count: 1, expected: ["s"]),
            TableCase(
                alphabet: "sadfjklewcmpgh",
                count: 14,
                expected: ["a", "c", "d", "e", "f", "g", "h", "j", "k", "l", "m", "p", "s", "w"]
            ),
            TableCase(
                alphabet: "sadfjklewcmpgh",
                count: 15,
                expected: ["a", "sa", "c", "d", "e", "f", "g", "h", "j", "k", "l", "m", "p", "ss", "w"]
            ),
            TableCase(alphabet: "sadf", count: 0, expected: []),
            TableCase(alphabet: "sadfjklewcmpgh", count: 0, expected: []),
            TableCase(alphabet: "ab", count: 0, expected: []),
        ]
    )
    func table(_ testCase: TableCase) throws {
        let labels = HintLabelGenerator.labels(count: testCase.count, alphabet: try alphabet(testCase.alphabet))

        #expect(labels == testCase.expected)
    }

    @Test("要素数が負なら空", arguments: [-1, -100])
    func negativeCount(count: Int) {
        #expect(HintLabelGenerator.labels(count: count, alphabet: .vimiumDefault).isEmpty)
    }

    @Test("要素数 1 でも空文字列のラベルを返さない（queue.count == 1 の条件）", arguments: ["ab", "sadf", "zyx"])
    func singleElementIsNotEmptyLabel(alphabetString: String) throws {
        let alphabet = try alphabet(alphabetString)

        let labels = HintLabelGenerator.labels(count: 1, alphabet: alphabet)

        // 1 回だけ展開されるので、ラベルは文字セットの先頭の 1 文字になる
        #expect(labels == [String(alphabet.characters[0])])
    }

    // 文字セットの長さ n に対し、ラベルの長さが変わる境界（n, n + 1, n^2 前後）と 1000 付近を選ぶ。
    // 1〜1000 を総当たりすると引数の組み合わせが多くなりすぎるため、代表値に絞る
    @Test(
        "性質: ラベル数 = 要素数、重複なし、接頭辞関係なし、長さの差は最大 1、文字セット内（F-3.3）",
        arguments: ["ab", "abc", "sadf", "sadfjklewcmpgh", "abcdefghijklmnopqrstuvwxyz"],
        [1, 2, 3, 4, 5, 8, 9, 13, 14, 15, 16, 25, 26, 27, 64, 100, 195, 196, 197, 500, 676, 677, 999, 1000]
    )
    func properties(alphabetString: String, count: Int) throws {
        let alphabet = try alphabet(alphabetString)

        let labels = HintLabelGenerator.labels(count: count, alphabet: alphabet)

        try Self.verifyProperties(labels, count: count, alphabet: alphabet)
    }

    @Test("性質: 既定の文字セットで要素数 1〜1000 のすべて（F-3.3）")
    func propertiesForEveryCountWithDefaultAlphabet() throws {
        for count in 1...1000 {
            let labels = HintLabelGenerator.labels(count: count, alphabet: .vimiumDefault)

            try Self.verifyProperties(labels, count: count, alphabet: .vimiumDefault)
        }
    }

    private static func verifyProperties(_ labels: [String], count: Int, alphabet: HintAlphabet) throws {
        #expect(labels.count == count, "count: \(count)")
        #expect(Set(labels).count == labels.count, "重複あり count: \(count)")

        let allowed = Set(alphabet.characters)
        #expect(labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(allowed.contains) }, "count: \(count)")

        let lengths = labels.map(\.count)
        let minLength = try #require(lengths.min())
        let maxLength = try #require(lengths.max())
        #expect(maxLength - minLength <= 1, "count: \(count)")

        // 辞書順に並べると、a が他のどれかの接頭辞なら、a は直後の要素の接頭辞でもある。
        // そのため隣り合う組だけ調べれば十分（総当たりの O(n^2) を避ける）
        let sorted = labels.sorted()
        for (shorter, longer) in zip(sorted, sorted.dropFirst()) {
            #expect(!longer.hasPrefix(shorter), "\(shorter) は \(longer) の接頭辞 count: \(count)")
        }
    }
}
