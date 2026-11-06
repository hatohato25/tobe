import Foundation

/// 設定を UserDefaults に平たいキーで保存する（design.md 12.2、D-22）。
///
/// 項目ごとに読み込み・検証するので、1 項目が壊れていても他の項目は保存値のまま使える。
@MainActor
public final class UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults

    /// テストでは `UserDefaults(suiteName:)` を渡す。
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> SettingsLoadResult {
        var issues: [SettingsIssue] = []
        let fallback = TobeSettings.defaults

        // 各項目: キーがなければ既定値（問題にしない）。値が不正なら既定値を使い、問題として記録する（D-22）
        func resolve<Value>(_ key: SettingsKey, default defaultValue: Value, _ result: ReadResult<Value>) -> Value {
            switch result {
            case .missing:
                return defaultValue
            case .value(let value):
                return value
            case .invalid(let reason):
                issues.append(.invalidValue(key, reason: reason))
                return defaultValue
            }
        }

        let triggerKey = resolve(.triggerKey, default: fallback.triggerKey, readTriggerKey())
        let alphabet = resolve(.hintCharacters, default: fallback.alphabet, readAlphabet())
        let fontSize = resolve(.labelFontSize, default: fallback.appearance.fontSize, readFontSize())
        let textColor = resolve(.labelTextColor, default: fallback.appearance.textColor, readColor(.labelTextColor))
        let backgroundColor = resolve(
            .labelBackgroundColor, default: fallback.appearance.backgroundColor, readColor(.labelBackgroundColor)
        )

        let appearance: LabelAppearance
        do {
            appearance = try LabelAppearance(
                fontSize: fontSize, textColor: textColor, backgroundColor: backgroundColor
            )
        } catch {
            // readFontSize が範囲を検証済みなので、ここには来ない
            preconditionFailure("検証済みのフォントサイズで LabelAppearance を作れなかった: \(error)")
        }

        return SettingsLoadResult(
            settings: TobeSettings(triggerKey: triggerKey, alphabet: alphabet, appearance: appearance),
            issues: issues
        )
    }

    public func save(_ settings: TobeSettings) {
        defaults.set(settings.triggerKey.rawValue, forKey: SettingsKey.triggerKey.rawValue)
        defaults.set(settings.alphabet.stringValue, forKey: SettingsKey.hintCharacters.rawValue)
        defaults.set(settings.appearance.fontSize, forKey: SettingsKey.labelFontSize.rawValue)
        defaults.set(settings.appearance.textColor.hexString, forKey: SettingsKey.labelTextColor.rawValue)
        defaults.set(
            settings.appearance.backgroundColor.hexString, forKey: SettingsKey.labelBackgroundColor.rawValue
        )
    }

    // MARK: - 項目ごとの読み込み

    /// 1 項目の読み込み結果。「キーがない」と「値が不正」を区別する。
    private enum ReadResult<Value> {
        case missing
        case value(Value)
        case invalid(reason: String)
    }

    /// 文字列の項目を読む。`string(forKey:)` は数値を文字列に変換してしまうため使わず、型を厳密に確認する。
    private func readString(_ key: SettingsKey) -> ReadResult<String> {
        guard let object = defaults.object(forKey: key.rawValue) else { return .missing }
        guard let string = object as? String else { return .invalid(reason: "文字列ではない") }
        return .value(string)
    }

    private func readTriggerKey() -> ReadResult<TriggerKey> {
        switch readString(.triggerKey) {
        case .missing: return .missing
        case .invalid(let reason): return .invalid(reason: reason)
        case .value(let string):
            guard let triggerKey = TriggerKey(rawValue: string) else {
                let choices = TriggerKey.allCases.map(\.rawValue).joined(separator: " / ")
                return .invalid(reason: "起動キーは \(choices) のどれか")
            }
            return .value(triggerKey)
        }
    }

    private func readAlphabet() -> ReadResult<HintAlphabet> {
        switch readString(.hintCharacters) {
        case .missing: return .missing
        case .invalid(let reason): return .invalid(reason: reason)
        case .value(let string):
            do {
                return .value(try HintAlphabet(validating: string))
            } catch {
                return .invalid(reason: "文字セットが不正: \(error)")
            }
        }
    }

    /// フォントサイズを読む。`double(forKey:)` は文字列を数値に変換し、読めない値を 0 にするため使わない。
    private func readFontSize() -> ReadResult<Double> {
        guard let object = defaults.object(forKey: SettingsKey.labelFontSize.rawValue) else { return .missing }
        // Bool も NSNumber として Double に変換できてしまうため、CFBoolean を先に除く
        guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return .invalid(reason: "数値ではない")
        }
        let fontSize = number.doubleValue
        guard LabelAppearance.fontSizeRange.contains(fontSize) else {
            let range = LabelAppearance.fontSizeRange
            return .invalid(reason: "フォントサイズは \(range.lowerBound)〜\(range.upperBound) の範囲")
        }
        return .value(fontSize)
    }

    private func readColor(_ key: SettingsKey) -> ReadResult<RGBAColor> {
        switch readString(key) {
        case .missing: return .missing
        case .invalid(let reason): return .invalid(reason: reason)
        case .value(let string):
            do {
                return .value(try RGBAColor(hex: string))
            } catch {
                return .invalid(reason: "色は #RRGGBBAA の形式: \(error)")
            }
        }
    }
}
