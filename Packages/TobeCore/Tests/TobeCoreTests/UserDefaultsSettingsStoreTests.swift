import Foundation
import Testing

@testable import TobeCore

/// テストごとに専用の suite を作り、終わったら片付ける。
///
/// テストは並列に走るため、suite 名に UUID を含めて一意にする。`UserDefaults.standard` は使わない。
@MainActor
private final class IsolatedDefaults {
    let suiteName = "io.github.hatohato25.tobe.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func store() -> UserDefaultsSettingsStore {
        UserDefaultsSettingsStore(defaults: defaults)
    }

    func set(_ value: Any, for key: SettingsKey) {
        defaults.set(value, forKey: key.rawValue)
    }
}

/// 既定値と全項目が異なる設定。
private func customSettings() throws -> TobeSettings {
    TobeSettings(
        triggerKey: .rightOption,
        alphabet: try HintAlphabet(validating: "asdfghjkl"),
        appearance: try LabelAppearance(
            fontSize: 20.5,
            textColor: RGBAColor(hex: "#11223344"),
            backgroundColor: RGBAColor(hex: "#AABBCCDD")
        )
    )
}

@MainActor
@Suite("設定の保存と読み込み（S-0.2、D-22）")
struct SettingsStoreRoundTripTests {
    @Test("キーがなければ既定値を使い、問題にしない")
    func emptyDefaults() throws {
        let isolated = try IsolatedDefaults()

        let result = isolated.store().load()

        #expect(result.settings == .defaults)
        #expect(result.issues.isEmpty)
    }

    @Test("保存した値を読み込める（再起動を想定して別のインスタンスで読む）")
    func roundTrip() throws {
        let isolated = try IsolatedDefaults()
        let settings = try customSettings()

        isolated.store().save(settings)
        let reopened = try #require(UserDefaults(suiteName: isolated.suiteName))
        let result = UserDefaultsSettingsStore(defaults: reopened).load()

        #expect(result.settings == settings)
        #expect(result.issues.isEmpty)
    }

    @Test("design.md 12.2 のキーと型で保存する（defaults read で確認できる形）")
    func savedRepresentation() throws {
        let isolated = try IsolatedDefaults()

        isolated.store().save(try customSettings())
        let defaults = isolated.defaults

        #expect(defaults.object(forKey: "triggerKey") as? String == "rightOption")
        #expect(defaults.object(forKey: "hintCharacters") as? String == "asdfghjkl")
        #expect(defaults.object(forKey: "labelFontSize") as? Double == 20.5)
        #expect(defaults.object(forKey: "labelTextColor") as? String == "#11223344")
        #expect(defaults.object(forKey: "labelBackgroundColor") as? String == "#AABBCCDD")
    }

    @Test("キーの一覧は design.md 12.2 の表と一致する（ログイン時の起動は含まない、D-22）")
    func keyList() {
        #expect(
            SettingsKey.allCases.map(\.rawValue) == [
                "triggerKey", "hintCharacters", "labelFontSize", "labelTextColor", "labelBackgroundColor",
            ]
        )
    }

    @Test("保存すると、それまでの不正な値は上書きされて問題がなくなる")
    func saveOverwritesInvalidValues() throws {
        let isolated = try IsolatedDefaults()
        isolated.set("leftCommand", for: .triggerKey)
        isolated.set(100.0, for: .labelFontSize)

        isolated.store().save(.defaults)
        let result = isolated.store().load()

        #expect(result.settings == .defaults)
        #expect(result.issues.isEmpty)
    }

    @Test("一部のキーだけあれば、その項目だけ保存値を使う")
    func partialKeys() throws {
        let isolated = try IsolatedDefaults()
        isolated.set("rightOption", for: .triggerKey)
        isolated.set(16, for: .labelFontSize)  // 整数で保存された値（defaults write -int）も読める

        let result = isolated.store().load()

        #expect(result.settings.triggerKey == .rightOption)
        #expect(result.settings.appearance.fontSize == 16)
        #expect(result.settings.alphabet == .vimiumDefault)
        #expect(result.settings.appearance.textColor == LabelAppearance.defaults.textColor)
        #expect(result.issues.isEmpty)
    }

    @Test("大文字で保存された文字セットは小文字にそろえて読む（S-2.3）")
    func uppercaseAlphabet() throws {
        let isolated = try IsolatedDefaults()
        isolated.set("SADF", for: .hintCharacters)

        let result = isolated.store().load()

        #expect(result.settings.alphabet.stringValue == "sadf")
        #expect(result.issues.isEmpty)
    }
}

@MainActor
@Suite("不正な保存値の扱い（S-0.3、D-22）")
struct SettingsStoreInvalidValueTests {
    struct InvalidValueCase: @unchecked Sendable, CustomTestStringConvertible {
        // `Any` はプロパティリストに入る値（String / NSNumber / Data / Array）だけを入れる
        let key: SettingsKey
        let value: Any
        let label: String
        var testDescription: String { "\(key.rawValue): \(label)" }
    }

    @Test(
        "不正な値はその項目だけ既定値を使い、SettingsIssue を返す",
        arguments: [
            InvalidValueCase(key: .triggerKey, value: "leftCommand", label: "未知の起動キー"),
            InvalidValueCase(key: .triggerKey, value: 1, label: "数値"),
            InvalidValueCase(key: .hintCharacters, value: "a", label: "1 文字"),
            InvalidValueCase(key: .hintCharacters, value: "aab", label: "重複"),
            InvalidValueCase(key: .hintCharacters, value: "ab1", label: "使えない文字"),
            InvalidValueCase(key: .hintCharacters, value: ["a", "b"], label: "配列"),
            InvalidValueCase(key: .labelFontSize, value: 7.5, label: "範囲より小さい"),
            InvalidValueCase(key: .labelFontSize, value: 33, label: "範囲より大きい"),
            InvalidValueCase(key: .labelFontSize, value: "12", label: "文字列"),
            InvalidValueCase(key: .labelFontSize, value: true, label: "真偽値"),
            InvalidValueCase(key: .labelTextColor, value: "#FFF", label: "短い"),
            InvalidValueCase(key: .labelTextColor, value: "red", label: "名前"),
            InvalidValueCase(key: .labelBackgroundColor, value: "FFD752F2", label: "# なし"),
            InvalidValueCase(key: .labelBackgroundColor, value: Data([0xFF]), label: "Data"),
        ]
    )
    func invalidValueFallsBackPerItem(_ testCase: InvalidValueCase) throws {
        let isolated = try IsolatedDefaults()
        let custom = try customSettings()
        isolated.store().save(custom)
        isolated.set(testCase.value, for: testCase.key)

        let result = isolated.store().load()

        // 問題はその項目の 1 件だけ
        #expect(result.issues.count == 1)
        guard case .invalidValue(let key, let reason) = result.issues.first else {
            Issue.record("SettingsIssue がない")
            return
        }
        #expect(key == testCase.key)
        #expect(!reason.isEmpty)
        // 壊れた項目は既定値、他の項目は保存値のまま
        #expect(result.settings == expectedSettings(custom: custom, resettingToDefault: testCase.key))
    }

    @Test("複数の項目が不正なら、それぞれの問題をキーの順に返す")
    func multipleInvalidValues() throws {
        let isolated = try IsolatedDefaults()
        isolated.set("#ZZZZZZZZ", for: .labelBackgroundColor)
        isolated.set("x", for: .hintCharacters)
        isolated.set("rightOption", for: .triggerKey)

        let result = isolated.store().load()

        #expect(result.issues.map(\.key) == [.hintCharacters, .labelBackgroundColor])
        #expect(result.settings.triggerKey == .rightOption)
        #expect(result.settings.alphabet == .vimiumDefault)
        #expect(result.settings.appearance.backgroundColor == LabelAppearance.defaults.backgroundColor)
    }

    @Test("範囲外のフォントサイズは保存できない（型で拒否される、S-3.2）")
    func outOfRangeFontSizeCannotBeSaved() throws {
        let isolated = try IsolatedDefaults()

        // LabelAppearance を作れないため、save に範囲外の値は渡らない
        #expect(throws: LabelAppearanceError.fontSizeOutOfRange(40)) {
            try LabelAppearance(
                fontSize: 40,
                textColor: LabelAppearance.defaults.textColor,
                backgroundColor: LabelAppearance.defaults.backgroundColor
            )
        }
        #expect(isolated.defaults.object(forKey: SettingsKey.labelFontSize.rawValue) == nil)
    }

    private func expectedSettings(custom: TobeSettings, resettingToDefault key: SettingsKey) -> TobeSettings {
        let fallback = TobeSettings.defaults
        var expected = custom
        switch key {
        case .triggerKey:
            expected.triggerKey = fallback.triggerKey
        case .hintCharacters:
            expected.alphabet = fallback.alphabet
        case .labelFontSize, .labelTextColor, .labelBackgroundColor:
            expected.appearance = expectedAppearance(custom: custom.appearance, resettingToDefault: key)
        }
        return expected
    }

    private func expectedAppearance(custom: LabelAppearance, resettingToDefault key: SettingsKey) -> LabelAppearance {
        let fallback = LabelAppearance.defaults
        do {
            return try LabelAppearance(
                fontSize: key == .labelFontSize ? fallback.fontSize : custom.fontSize,
                textColor: key == .labelTextColor ? fallback.textColor : custom.textColor,
                backgroundColor: key == .labelBackgroundColor ? fallback.backgroundColor : custom.backgroundColor
            )
        } catch {
            Issue.record("期待値を作れない: \(error)")
            return fallback
        }
    }
}

extension SettingsIssue {
    fileprivate var key: SettingsKey {
        switch self {
        case .invalidValue(let key, _): key
        }
    }
}
