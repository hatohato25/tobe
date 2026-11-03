import Foundation
import Testing

@testable import TobiCore

@Suite("RGBA の色（S-3、暫定 Q-21）")
struct RGBAColorTests {
    @Test("#RRGGBBAA を成分に分ける")
    func parsesHex() throws {
        let color = try RGBAColor(hex: "#FF8000CC")

        #expect(color.red == 1)
        #expect(color.green == Double(0x80) / 255)
        #expect(color.blue == 0)
        #expect(color.alpha == Double(0xCC) / 255)
    }

    @Test("小文字の 16 進も受け付け、hexString は大文字で返す")
    func acceptsLowercase() throws {
        let color = try RGBAColor(hex: "#ffd752f2")

        #expect(color.hexString == "#FFD752F2")
        #expect(color == (try RGBAColor(hex: "#FFD752F2")))
    }

    @Test(
        "hex から作った値は hexString で同じ文字列に戻る",
        arguments: ["#00000000", "#FFFFFFFF", "#302505FF", "#FFD752F2", "#0A0B0C0D", "#7F808101"]
    )
    func roundTrip(hex: String) throws {
        #expect(try RGBAColor(hex: hex).hexString == hex)
    }

    struct InvalidHexCase: Sendable, CustomTestStringConvertible {
        let input: String
        let error: RGBAColorError
        var testDescription: String { input.isEmpty ? "(空)" : input }
    }

    @Test(
        "#RRGGBBAA でない文字列は理由つきで拒否する",
        arguments: [
            InvalidHexCase(input: "", error: .missingHashPrefix),
            InvalidHexCase(input: "FFD752F2", error: .missingHashPrefix),
            InvalidHexCase(input: "#", error: .invalidLength(digitCount: 0)),
            InvalidHexCase(input: "#FFD752", error: .invalidLength(digitCount: 6)),
            InvalidHexCase(input: "#FFD752F2A", error: .invalidLength(digitCount: 9)),
            InvalidHexCase(input: "#GGD752F2", error: .invalidHexDigit("G")),
            InvalidHexCase(input: "#FFD752F ", error: .invalidHexDigit(" ")),
            InvalidHexCase(input: "#-1D752F2", error: .invalidHexDigit("-")),
            // 全角の数字（Character.hexDigitValue なら通ってしまう）
            InvalidHexCase(input: "#ＦＦD752F2", error: .invalidHexDigit("Ｆ")),
        ]
    )
    func rejectsInvalidHex(_ testCase: InvalidHexCase) {
        #expect(throws: testCase.error) {
            try RGBAColor(hex: testCase.input)
        }
    }

    @Test("成分から作れる（境界の 0 と 1 を含む）")
    func componentsInit() throws {
        let color = try RGBAColor(red: 0, green: 0.5, blue: 1, alpha: 1)

        #expect(color.red == 0)
        #expect(color.green == 0.5)
        #expect(color.blue == 1)
        #expect(color.hexString == "#0080FFFF")
    }

    struct OutOfRangeCase: Sendable, CustomTestStringConvertible {
        let components: [Double]
        let component: RGBAColorComponent
        var testDescription: String { "\(component.rawValue) = \(components)" }
    }

    @Test(
        "0...1 の外や NaN の成分は拒否する",
        arguments: [
            OutOfRangeCase(components: [-0.01, 0, 0, 0], component: .red),
            OutOfRangeCase(components: [0, 1.01, 0, 0], component: .green),
            OutOfRangeCase(components: [0, 0, .nan, 0], component: .blue),
            OutOfRangeCase(components: [0, 0, 0, .infinity], component: .alpha),
        ]
    )
    func rejectsOutOfRangeComponents(_ testCase: OutOfRangeCase) {
        let values = testCase.components
        #expect(throws: RGBAColorError.componentOutOfRange(testCase.component)) {
            try RGBAColor(red: values[0], green: values[1], blue: values[2], alpha: values[3])
        }
    }
}
