import Foundation
import Testing

@testable import TobiCore

@Suite("ラベルの見た目（S-3、暫定 Q-21）")
struct LabelAppearanceTests {
    @Test("既定は 12pt、文字色 #302505FF、背景色 #FFD752F2")
    func defaults() {
        let appearance = LabelAppearance.defaults

        #expect(appearance.fontSize == 12)
        #expect(appearance.textColor.hexString == "#302505FF")
        #expect(appearance.backgroundColor.hexString == "#FFD752F2")
        #expect(LabelAppearance.fontSizeRange == 8...32)
    }

    @Test("既定値は検証を通した値と等しい（不変条件を満たしている）")
    func defaultsSatisfyValidation() throws {
        let validated = try LabelAppearance(
            fontSize: 12,
            textColor: RGBAColor(hex: "#302505FF"),
            backgroundColor: RGBAColor(hex: "#FFD752F2")
        )

        #expect(validated == LabelAppearance.defaults)
    }

    @Test("範囲内のフォントサイズは受け付ける（境界を含む）", arguments: [8.0, 8.5, 12, 31.9, 32])
    func acceptsFontSizeInRange(fontSize: Double) throws {
        let appearance = try LabelAppearance(
            fontSize: fontSize,
            textColor: LabelAppearance.defaults.textColor,
            backgroundColor: LabelAppearance.defaults.backgroundColor
        )

        #expect(appearance.fontSize == fontSize)
    }

    @Test(
        "範囲外のフォントサイズは拒否する（S-3.2）",
        arguments: [7.99, 0, -12, 32.01, 100, .infinity, -.infinity, .nan]
    )
    func rejectsFontSizeOutOfRange(fontSize: Double) {
        #expect(throws: LabelAppearanceError.fontSizeOutOfRange(fontSize)) {
            try LabelAppearance(
                fontSize: fontSize,
                textColor: LabelAppearance.defaults.textColor,
                backgroundColor: LabelAppearance.defaults.backgroundColor
            )
        }
    }

    @Test("TobiSettings の既定値（S-1.1、S-2.1）")
    func settingsDefaults() {
        let settings = TobiSettings.defaults

        #expect(settings.triggerKey == .rightCommand)
        #expect(settings.alphabet == .vimiumDefault)
        #expect(settings.appearance == .defaults)
    }
}
