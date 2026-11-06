import Foundation
import Observation
import TobeCore

/// 設定画面（T53）とアプリ（T54）が共有する設定の状態（S-0〜S-3、design.md 12.1・12.2）。
///
/// - 生成時に `SettingsStoring.load()` で読み込む。読めなかった項目（`SettingsIssue`）はログに出し、
///   `loadIssues` として設定画面に出せるように持つ（S-0.3、D-22）。黙って既定値にしない。
/// - 設定画面からの入力は、項目ごとの型（`HintAlphabet`、`LabelAppearance`、`RGBAColor`）の検証を通ったものだけを
///   保存する（S-2.2、S-3.2）。通らなかった入力は保存せず、理由を `alphabetError` などに持つ（画面のその場に出すため）。
/// - 起動キーの変更は、すぐに `applyTriggerKey`（T54 が `EventTapController.updateTriggerKey(_:)` を結ぶ）に渡す。
///   文字セットと見た目は、Coordinator が次のヒントモードの開始時に `settings` を読む（暫定 Q-23、S-0.4）。
/// - ログイン時の起動（S-4）は持たない。`SMAppService` の状態を正とするため、T53 が `LaunchAtLoginService` を直接使う（D-22）。
@MainActor
@Observable
final class SettingsModel {
    /// 現在の設定。保存済みの値と常に一致する（検証に通らない入力では変わらない）。
    private(set) var settings: TobeSettings

    /// 起動時の読み込みで見つかった問題（S-0.3）。並びは `SettingsKey.allCases` の順。
    /// その項目には既定値を使っている。読み込みは起動時の 1 回だけなので、アプリを終了するまで変わらない。
    let loadIssues: [SettingsIssue]

    /// 直近の文字セットの入力が検証に通らなかった理由（S-2.2）。通る入力を保存すると `nil` に戻る。
    private(set) var alphabetError: HintAlphabetError?
    /// 直近のフォントサイズの入力が範囲外だった理由（S-3.2）。通る入力を保存すると `nil` に戻る。
    private(set) var fontSizeError: LabelAppearanceError?
    /// 直近の文字色の入力が検証に通らなかった理由。通る入力を保存すると `nil` に戻る。
    private(set) var textColorError: RGBAColorError?
    /// 直近の背景色の入力が検証に通らなかった理由。通る入力を保存すると `nil` に戻る。
    private(set) var backgroundColorError: RGBAColorError?

    @ObservationIgnored private let store: any SettingsStoring
    @ObservationIgnored private let applyTriggerKey: @MainActor (TriggerKey) -> Void

    /// - Parameters:
    ///   - store: 設定の保存先。アプリでは `UserDefaultsSettingsStore(defaults: .standard)`。
    ///   - applyTriggerKey: 起動キーが変わったときに呼ぶ。T54 が `EventTapController.updateTriggerKey(_:)` を結ぶ。
    ///     読み込んだ起動キーは渡さない（`EventTapController` の生成時に `settings.triggerKey` を渡す。
    ///     Debug の `--trigger-key` はその生成時に設定の値より優先される）。
    init(store: any SettingsStoring, applyTriggerKey: @escaping @MainActor (TriggerKey) -> Void) {
        self.store = store
        self.applyTriggerKey = applyTriggerKey
        let result = store.load()
        settings = result.settings
        loadIssues = result.issues
        for issue in result.issues {
            Self.log(issue)
        }
    }

    /// `loadIssues` を設定画面に出すための文（S-0.3）。並びは `loadIssues` と同じ。
    ///
    /// `SettingsIssue` の `reason` は TobeCore の日本語の固定文で、ローカライズできないため画面には入れない（ログには出す）。
    var loadIssueMessages: [String] {
        loadIssues.map(Self.message(for:))
    }

    // MARK: - 設定画面からの入力

    /// 起動キーを変えて保存し、すぐに反映する（S-1.1、暫定 Q-23）。同じ値なら何もしない。
    func updateTriggerKey(_ triggerKey: TriggerKey) {
        guard settings.triggerKey != triggerKey else { return }
        settings.triggerKey = triggerKey
        store.save(settings)
        applyTriggerKey(triggerKey)
        Log.settings.notice("起動キーを保存した: \(triggerKey.rawValue, privacy: .public)")
    }

    /// 文字セットを検証し、通れば保存する（S-2.2、S-2.3）。英大文字は小文字にそろえて保存する。
    /// 通らなければ保存せず、理由を `alphabetError` に入れる。反映は次のヒントモードから。
    func updateAlphabet(_ text: String) {
        let alphabet: HintAlphabet
        do {
            alphabet = try HintAlphabet(validating: text)
        } catch {
            alphabetError = error
            Self.logRejection(.hintCharacters, reason: Self.caseName(of: error))
            return
        }
        alphabetError = nil
        guard settings.alphabet != alphabet else { return }
        settings.alphabet = alphabet
        store.save(settings)
        Log.settings.notice("文字セットを保存した: \(alphabet.characters.count, privacy: .public) 文字")
    }

    /// フォントサイズを検証し、範囲内なら保存する（S-3.2）。範囲外なら保存せず、理由を `fontSizeError` に入れる。
    func updateFontSize(_ fontSize: Double) {
        let current = settings.appearance
        let appearance: LabelAppearance
        do {
            appearance = try LabelAppearance(
                fontSize: fontSize, textColor: current.textColor, backgroundColor: current.backgroundColor
            )
        } catch {
            fontSizeError = error
            Self.logRejection(.labelFontSize, reason: Self.caseName(of: error))
            return
        }
        fontSizeError = nil
        save(appearance, key: .labelFontSize)
    }

    /// 文字色を sRGB の成分（0...1）から作り、通れば保存する。成分が範囲外なら保存せず、理由を `textColorError` に入れる。
    ///
    /// オーバーレイは `RGBAColor` を sRGB として描く（T44）ので、呼び出し側は sRGB に変換してから渡す。
    func updateTextColor(red: Double, green: Double, blue: Double, alpha: Double) {
        let color: RGBAColor
        do {
            color = try RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
        } catch {
            textColorError = error
            Self.logRejection(.labelTextColor, reason: Self.caseName(of: error))
            return
        }
        textColorError = nil
        let current = settings.appearance
        save(
            Self.appearance(fontSize: current.fontSize, textColor: color, backgroundColor: current.backgroundColor),
            key: .labelTextColor
        )
    }

    /// 背景色を sRGB の成分（0...1）から作り、通れば保存する。成分が範囲外なら保存せず、理由を `backgroundColorError` に入れる。
    func updateBackgroundColor(red: Double, green: Double, blue: Double, alpha: Double) {
        let color: RGBAColor
        do {
            color = try RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
        } catch {
            backgroundColorError = error
            Self.logRejection(.labelBackgroundColor, reason: Self.caseName(of: error))
            return
        }
        backgroundColorError = nil
        let current = settings.appearance
        save(
            Self.appearance(fontSize: current.fontSize, textColor: current.textColor, backgroundColor: color),
            key: .labelBackgroundColor
        )
    }

    /// 全項目を既定値（`TobeSettings.defaults`）に戻して保存する（S-0.5）。起動キーはすぐに反映する。
    /// ログイン時の起動は戻さない。設定の値ではなく、ユーザーが OS に登録した状態のため（D-22）。
    func resetToDefaults() {
        alphabetError = nil
        fontSizeError = nil
        textColorError = nil
        backgroundColorError = nil
        let previousTriggerKey = settings.triggerKey
        settings = .defaults
        store.save(settings)
        if previousTriggerKey != settings.triggerKey {
            applyTriggerKey(settings.triggerKey)
        }
        Log.settings.notice("設定を既定値に戻した")
    }

    // MARK: - 内部

    /// 見た目を保存する。同じ値なら書き込まない（`ColorPicker` は同じ色を何度も送ることがあるため）。
    private func save(_ appearance: LabelAppearance, key: SettingsKey) {
        guard settings.appearance != appearance else { return }
        settings.appearance = appearance
        store.save(settings)
        Log.settings.notice("見た目を保存した: \(key.rawValue, privacy: .public)")
    }

    /// 今の（検証済みの）フォントサイズで見た目を作り直す。色だけを変えるときに使う。
    private static func appearance(
        fontSize: Double, textColor: RGBAColor, backgroundColor: RGBAColor
    ) -> LabelAppearance {
        do {
            return try LabelAppearance(fontSize: fontSize, textColor: textColor, backgroundColor: backgroundColor)
        } catch {
            // fontSize は既存の LabelAppearance から取った検証済みの値なので、ここには来ない
            preconditionFailure("検証済みのフォントサイズで LabelAppearance を作れなかった: \(error)")
        }
    }

    private static func message(for issue: SettingsIssue) -> String {
        switch issue {
        case .invalidValue(let key, _):
            let item = itemName(of: key)
            return String(
                localized: "The saved value for \(item) was invalid, so the default value is used.",
                comment: "Settings: a saved setting could not be read at launch. The argument is the item name"
            )
        }
    }

    private static func itemName(of key: SettingsKey) -> String {
        switch key {
        case .triggerKey:
            String(localized: "Trigger Key", comment: "Settings: item name of the trigger key")
        case .hintCharacters:
            String(localized: "Hint Characters", comment: "Settings: item name of the hint characters")
        case .labelFontSize:
            String(localized: "Font Size", comment: "Settings: item name of the label font size")
        case .labelTextColor:
            String(localized: "Text Color", comment: "Settings: item name of the label text color")
        case .labelBackgroundColor:
            String(localized: "Background Color", comment: "Settings: item name of the label background color")
        }
    }

    /// 読み込みの問題をログに出す（S-0.3）。`reason` は保存値そのものを含まない説明だが、
    /// 検証エラーの関連値（文字など）が入りうるので private にする。キーは固定の語彙なので public。
    private static func log(_ issue: SettingsIssue) {
        switch issue {
        case .invalidValue(let key, let reason):
            Log.settings.error(
                "保存値が不正なため既定値を使う: \(key.rawValue, privacy: .public) 理由: \(reason, privacy: .private)"
            )
        }
    }

    /// 保存しなかった入力をログに出す。入力そのもの（文字や値）は出さず、エラーの case 名だけを出す。
    private static func logRejection(_ key: SettingsKey, reason: String) {
        Log.settings.info("入力が検証に通らないため保存しない: \(key.rawValue, privacy: .public) \(reason, privacy: .public)")
    }

    /// エラーの case 名（関連値を除く）。関連値にはユーザーの入力が入るため、ログには case 名だけを使う。
    private static func caseName(of error: HintAlphabetError) -> String {
        switch error {
        case .tooFewCharacters: "tooFewCharacters"
        case .duplicateCharacter: "duplicateCharacter"
        case .unsupportedCharacter: "unsupportedCharacter"
        }
    }

    private static func caseName(of error: LabelAppearanceError) -> String {
        switch error {
        case .fontSizeOutOfRange: "fontSizeOutOfRange"
        }
    }

    private static func caseName(of error: RGBAColorError) -> String {
        switch error {
        case .missingHashPrefix: "missingHashPrefix"
        case .invalidLength: "invalidLength"
        case .invalidHexDigit: "invalidHexDigit"
        // どの成分かは入力の値ではないので出してよい
        case .componentOutOfRange(let component): "componentOutOfRange(\(component.rawValue))"
        }
    }
}
