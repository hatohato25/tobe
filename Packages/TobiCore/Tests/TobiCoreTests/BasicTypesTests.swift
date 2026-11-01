import Foundation
import Testing

@testable import TobiCore

// TobiCore と同じく Foundation だけを import するため、`CGRect(x:y:width:height:)` や `CGPoint` の `==`
// （CoreGraphics overlay にある）は使えない。矩形は origin / size から作り、点は成分ごとに比べる。
private func makeRect(x: Double, y: Double, width: Double, height: Double) -> GlobalRect {
    GlobalRect(rect: CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height)))
}

@Suite("GlobalRect")
struct GlobalRectTests {
    struct CenterCase: Sendable, CustomTestStringConvertible {
        let rect: GlobalRect
        // `center.x`（CGFloat）と同じ型にする。TobiCore が CoreGraphics を import するようになってから（D-28）、
        // `#expect(center.x == expectedX)` で CGFloat と Double を比べると、値が同じでも失敗するため
        let expectedX: CGFloat
        let expectedY: CGFloat
        var testDescription: String {
            "(\(rect.rect.origin.x), \(rect.rect.origin.y), \(rect.rect.size.width), \(rect.rect.size.height))"
        }
    }

    @Test(
        "center は矩形の中心点",
        arguments: [
            CenterCase(rect: makeRect(x: 0, y: 0, width: 100, height: 50), expectedX: 50, expectedY: 25),
            CenterCase(rect: makeRect(x: 10, y: 20, width: 30, height: 40), expectedX: 25, expectedY: 40),
            // 主ディスプレイの左・上にある副ディスプレイでは座標が負になる
            CenterCase(rect: makeRect(x: -1920, y: -1080, width: 1920, height: 1080), expectedX: -960, expectedY: -540),
            CenterCase(rect: makeRect(x: 5, y: 5, width: 0, height: 0), expectedX: 5, expectedY: 5),
            CenterCase(rect: makeRect(x: 0, y: 0, width: 3, height: 3), expectedX: 1.5, expectedY: 1.5),
        ]
    )
    func center(_ testCase: CenterCase) {
        let center = testCase.rect.center

        #expect(center.x == testCase.expectedX)
        #expect(center.y == testCase.expectedY)
    }

    @Test("すべての成分が等しいときだけ等しい")
    func equality() {
        let base = makeRect(x: 1, y: 2, width: 3, height: 4)

        #expect(base == makeRect(x: 1, y: 2, width: 3, height: 4))
        #expect(base != makeRect(x: 0, y: 2, width: 3, height: 4))
        #expect(base != makeRect(x: 1, y: 0, width: 3, height: 4))
        #expect(base != makeRect(x: 1, y: 2, width: 0, height: 4))
        #expect(base != makeRect(x: 1, y: 2, width: 3, height: 0))
    }
}

@Suite("TriggerKey")
struct TriggerKeyTests {
    @Test("keyCode は右 ⌘ が 0x36、右 ⌥ が 0x3D")
    func keyCode() {
        #expect(TriggerKey.rightCommand.keyCode == 0x36)
        #expect(TriggerKey.rightOption.keyCode == 0x3D)
    }

    @Test("deviceFlag は右側のデバイス依存ビット")
    func deviceFlag() {
        #expect(TriggerKey.rightCommand.deviceFlag == .deviceRightCommand)
        #expect(TriggerKey.rightOption.deviceFlag == .deviceRightOption)
    }

    @Test("設定に保存する raw value は変えない")
    func rawValue() throws {
        #expect(TriggerKey.allCases == [.rightCommand, .rightOption])
        #expect(TriggerKey(rawValue: "rightCommand") == .rightCommand)
        #expect(TriggerKey(rawValue: "rightOption") == .rightOption)

        let data = try JSONEncoder().encode(TriggerKey.rightOption)
        #expect(String(bytes: data, encoding: .utf8) == "\"rightOption\"")
        #expect(try JSONDecoder().decode(TriggerKey.self, from: data) == .rightOption)
    }
}

@Suite("ModifierFlags")
struct ModifierFlagsTests {
    @Test(
        "各ビットの値が IOLLEvent.h の定数と一致する",
        arguments: [
            (ModifierFlags.alphaShift, UInt64(0x0001_0000)),
            (ModifierFlags.shift, UInt64(0x0002_0000)),
            (ModifierFlags.control, UInt64(0x0004_0000)),
            (ModifierFlags.option, UInt64(0x0008_0000)),
            (ModifierFlags.command, UInt64(0x0010_0000)),
            (ModifierFlags.secondaryFn, UInt64(0x0080_0000)),
            (ModifierFlags.deviceLeftCommand, UInt64(0x0000_0008)),
            (ModifierFlags.deviceRightCommand, UInt64(0x0000_0010)),
            (ModifierFlags.deviceLeftOption, UInt64(0x0000_0020)),
            (ModifierFlags.deviceRightOption, UInt64(0x0000_0040)),
        ]
    )
    func bitValue(flag: ModifierFlags, expected: UInt64) {
        #expect(flag.rawValue == expected)
    }

    @Test("生の値から作ると、立っているビットだけを含む")
    func fromRawValue() {
        // 右 ⌘ を押したときの CGEventFlags（command + deviceRightCommand + 常に立つ 0x100）
        let flags = ModifierFlags(rawValue: 0x0010_0110)

        #expect(flags.contains(.command))
        #expect(flags.contains(.deviceRightCommand))
        #expect(!flags.contains(.deviceLeftCommand))
        #expect(!flags.contains(.option))
        #expect(!flags.contains(.alphaShift))
    }
}

@Suite("Timestamp")
struct TimestampTests {
    @Test("ナノ秒の大小で比較する")
    func comparison() {
        let earlier = Timestamp(nanoseconds: 1_000)
        let later = Timestamp(nanoseconds: 1_001)

        #expect(earlier < later)
        #expect(later > earlier)
        #expect(!(earlier < Timestamp(nanoseconds: 1_000)))
        #expect(earlier <= Timestamp(nanoseconds: 1_000))
        #expect(earlier == Timestamp(nanoseconds: 1_000))
        #expect(earlier != later)
    }

    @Test("UInt64 の境界値でも比較できる")
    func boundary() {
        let values = [Timestamp(nanoseconds: 3), Timestamp(nanoseconds: 0), Timestamp(nanoseconds: UInt64.max)]

        #expect(Timestamp(nanoseconds: 0) < Timestamp(nanoseconds: UInt64.max))
        #expect(values.max() == Timestamp(nanoseconds: UInt64.max))
        #expect(values.min() == Timestamp(nanoseconds: 0))
    }
}
