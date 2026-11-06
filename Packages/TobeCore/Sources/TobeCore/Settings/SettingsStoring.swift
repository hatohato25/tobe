import Foundation

/// UserDefaults のキー（design.md 12.2）。raw value がそのままキーの文字列になる。
public enum SettingsKey: String, CaseIterable, Sendable {
    /// String: `rightCommand` / `rightOption`
    case triggerKey
    /// String: 例 `sadfjklewcmpgh`
    case hintCharacters
    /// Double: 8...32
    case labelFontSize
    /// String: `#RRGGBBAA`
    case labelTextColor
    /// String: `#RRGGBBAA`
    case labelBackgroundColor
}

/// 保存値の読み込みで見つかった問題（S-0.3、D-22）。
///
/// 値はあるが検証に通らない項目ごとに 1 つ作る。その項目には既定値を使う。キーがないのは正常な状態なので、問題にしない。
public enum SettingsIssue: Equatable, Sendable {
    /// `reason` はログと設定画面に出すための説明。保存されていた値そのものは含めない。
    case invalidValue(SettingsKey, reason: String)
}

/// 設定の読み込み結果。
public struct SettingsLoadResult: Equatable, Sendable {
    /// 読み込んだ設定。不正な項目は既定値になっている。
    public let settings: TobeSettings
    /// 空でなければ、`SettingsModel` がログと設定画面に出す（S-0.3）。並びは `SettingsKey.allCases` の順。
    public let issues: [SettingsIssue]

    public init(settings: TobeSettings, issues: [SettingsIssue]) {
        self.settings = settings
        self.issues = issues
    }
}

/// 設定の保存先の抽象（design.md 12.2）。
@MainActor
public protocol SettingsStoring {
    func load() -> SettingsLoadResult
    /// すべての項目を書き込む。`TobeSettings` の値は型によって検証済みなので、失敗しない。
    func save(_ settings: TobeSettings)
}
