import Foundation

/// UserDefaults に保存する設定（S-1〜S-3、design.md 12.1）。
///
/// ログイン時の起動（S-4）は含めない。`SMAppService` の状態を正とし、保存しないため（D-22）。
/// 各項目の型（`HintAlphabet`、`LabelAppearance`）が値の検証を担うので、この型の値は常に保存してよい値になる。
public struct TobiSettings: Equatable, Sendable {
    /// 起動キー。既定は右 ⌘（S-1.1）。
    public var triggerKey: TriggerKey
    /// ラベルの文字セット。既定は `sadfjklewcmpgh`（S-2.1）。
    public var alphabet: HintAlphabet
    /// ラベルの見た目（S-3）。
    public var appearance: LabelAppearance

    public static let defaults = TobiSettings(
        triggerKey: .rightCommand,
        alphabet: .vimiumDefault,
        appearance: .defaults
    )

    public init(triggerKey: TriggerKey, alphabet: HintAlphabet, appearance: LabelAppearance) {
        self.triggerKey = triggerKey
        self.alphabet = alphabet
        self.appearance = appearance
    }
}
