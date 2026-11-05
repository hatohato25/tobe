// swiftlint:disable file_length
// 設定画面の行のビュー・文言・プレビューを private の型でこのファイルに閉じ込めているため 400 行を超える。
// 別のファイルに分けると、これらの型を internal に開く必要がある（T53 の担当ファイルの制約もある）。

import AppKit
import Observation
import SwiftUI
import TobiCore

// MARK: - 設定画面

/// 設定画面（S-0.1〜S-4、design.md 12.4）。`SettingsWindowController` が `NSWindow` に載せる（D-24）。
///
/// - 入力は `SettingsModel` の更新メソッドに渡すだけにする。検証と保存はモデルが行い、通らなかった理由はモデルの
///   `…Error` から出す（S-2.2、S-3.2）。
/// - 文字セットとフォントサイズは、入力中の文字列（下書き）を子のビューの `@State` に持つ。ウィンドウは使い回すので、
///   `SettingsWindowController` は開くたびに `sessionID` を変えて下書きを保存済みの値に戻す。
struct SettingsView: View {
    let model: SettingsModel
    let launchAtLogin: LaunchAtLoginModel
    /// 画面を開くたびに変わる値。変わると入力欄の下書きを作り直す。
    let sessionID: UUID
    /// 既定値に戻すたびに変わる値。変わると入力欄の下書きを作り直す。
    @State private var resetID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.loadIssueMessages.isEmpty {
                LoadIssuesBanner(messages: model.loadIssueMessages)
            }
            Form {
                Section {
                    triggerKeyPicker
                }
                Section {
                    HintCharactersField(model: model)
                    FontSizeField(model: model)
                    colorRow(
                        title: SettingsStrings.textColor,
                        color: model.settings.appearance.textColor,
                        error: model.textColorError,
                        update: model.updateTextColor(red:green:blue:alpha:)
                    )
                    colorRow(
                        title: SettingsStrings.backgroundColor,
                        color: model.settings.appearance.backgroundColor,
                        error: model.backgroundColorError,
                        update: model.updateBackgroundColor(red:green:blue:alpha:)
                    )
                }
                Section {
                    LaunchAtLoginRow(model: launchAtLogin)
                }
            }
            .formStyle(.columns)
            .id(sessionID)
            .id(resetID)
            HStack {
                Spacer()
                Button(SettingsStrings.restoreDefaults) {
                    model.resetToDefaults()
                    resetID = UUID()
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var triggerKeyPicker: some View {
        Picker(
            SettingsStrings.triggerKey,
            selection: Binding(
                get: { model.settings.triggerKey },
                set: { model.updateTriggerKey($0) }
            )
        ) {
            ForEach(TriggerKey.allCases, id: \.self) { key in
                Text(SettingsStrings.name(of: key)).tag(key)
            }
        }
        .pickerStyle(.radioGroup)
    }

    private func colorRow(
        title: String,
        color: RGBAColor,
        error: RGBAColorError?,
        update: @escaping @MainActor (Double, Double, Double, Double) -> Void
    ) -> some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                ColorPicker(
                    title,
                    selection: Binding(
                        get: {
                            Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
                        },
                        set: { newColor in
                            guard let components = SRGBComponents(newColor) else { return }
                            update(components.red, components.green, components.blue, components.alpha)
                        }
                    ),
                    supportsOpacity: true
                )
                .labelsHidden()
                // 文字のないコントロールは下端が行揃えの基準になり、ラベルより上にずれる。見た目の中央を文字に合わせる
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                if let error {
                    ErrorText(SettingsStrings.message(for: error))
                }
            }
        }
    }
}

/// `ColorPicker` の色を、オーバーレイが描く色空間（sRGB。T44）の成分にしたもの。
private struct SRGBComponents {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    /// sRGB に変換できない色（パターンなど）では `nil`。その色は保存しない。
    init?(_ color: Color) {
        // sRGB の外の色（Display P3 など）は、この変換で sRGB の範囲に写される。
        // 範囲の検証は SettingsModel（RGBAColor）が行い、通らなければ理由が画面に出る
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            Log.settings.error("選ばれた色を sRGB に変換できないため保存しない")
            return nil
        }
        red = Double(srgb.redComponent)
        green = Double(srgb.greenComponent)
        blue = Double(srgb.blueComponent)
        alpha = Double(srgb.alphaComponent)
    }
}

/// 起動時の読み込みで見つかった問題（S-0.3）。
private struct LoadIssuesBanner: View {
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(messages, id: \.self) { message in
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 文字セットの入力欄（S-2.1〜S-2.3）。入力が変わるたびにモデルへ渡し、通らなければ理由をその場に出す。
private struct HintCharactersField: View {
    let model: SettingsModel
    @State private var text: String

    init(model: SettingsModel) {
        self.model = model
        _text = State(initialValue: model.settings.alphabet.stringValue)
    }

    var body: some View {
        LabeledContent(SettingsStrings.hintCharacters) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(SettingsStrings.hintCharacters, text: $text)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .onChange(of: text) { _, newValue in model.updateAlphabet(newValue) }
                    // 英大文字は小文字にそろえて保存される（S-2.3）。確定したら、保存された値を欄にも出す
                    .onSubmit { normalizeIfSaved() }
                if let error = visibleError {
                    ErrorText(SettingsStrings.message(for: error))
                } else {
                    Text(SettingsStrings.hintCharactersHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 欄の内容が保存済みの値と同じなら、理由は出さない。`alphabetError` はアプリの終了まで残るため、
    /// 開き直して下書きが保存済みの値に戻ったときに、前回の理由を出さないようにする。
    private var visibleError: HintAlphabetError? {
        guard let error = model.alphabetError, text != model.settings.alphabet.stringValue else { return nil }
        return error
    }

    private func normalizeIfSaved() {
        guard model.alphabetError == nil else { return }
        text = model.settings.alphabet.stringValue
    }
}

/// フォントサイズの入力欄（S-3.1、S-3.2）。数値の欄と Stepper のどちらで変えてもモデルへ渡す。
private struct FontSizeField: View {
    let model: SettingsModel
    @State private var fontSize: Double

    init(model: SettingsModel) {
        self.model = model
        _fontSize = State(initialValue: model.settings.appearance.fontSize)
    }

    var body: some View {
        LabeledContent(SettingsStrings.fontSize) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    // 数値の欄は範囲外の値も受け付ける。保存するかどうかはモデルが決め、範囲外なら理由を出す
                    TextField(SettingsStrings.fontSize, value: $fontSize, format: .number)
                        .labelsHidden()
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Stepper(SettingsStrings.fontSize, value: $fontSize, in: LabelAppearance.fontSizeRange, step: 1)
                        .labelsHidden()
                    Text(SettingsStrings.points)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: fontSize) { _, newValue in model.updateFontSize(newValue) }
                if model.fontSizeError != nil, fontSize != model.settings.appearance.fontSize {
                    ErrorText(SettingsStrings.fontSizeOutOfRange)
                }
            }
        }
    }
}

/// ログイン時の起動のトグルと、承認待ち・失敗の表示（S-4.1〜S-4.4）。
private struct LaunchAtLoginRow: View {
    let model: LaunchAtLoginModel

    var body: some View {
        LabeledContent(SettingsStrings.launchAtLoginSection) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    SettingsStrings.launchAtLogin,
                    isOn: Binding(
                        get: { model.isOn },
                        set: { newValue in
                            // オンとオフで呼ぶ操作が違う（register / unregister）。表示は操作の戻り値で決まる
                            guard newValue != model.isOn else { return }
                            if newValue {
                                model.turnOn()
                            } else {
                                model.turnOff()
                            }
                        }
                    )
                )
                statusNote
                if let message = model.failureMessage {
                    ErrorText(message)
                }
            }
        }
    }

    @ViewBuilder
    private var statusNote: some View {
        switch model.status {
        case .requiresApproval:
            Text(SettingsStrings.launchAtLoginRequiresApproval)
                .fixedSize(horizontal: false, vertical: true)
            Button(SettingsStrings.openLoginItems) { model.openSystemSettingsLoginItems() }
        case .notFound:
            if model.turnOnFoundNoService {
                ErrorText(SettingsStrings.launchAtLoginNotFound)
            }
        case .enabled, .notRegistered, nil:
            EmptyView()
        }
    }
}

/// 入力の検証や操作の失敗の理由。
private struct ErrorText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "xmark.octagon.fill")
        }
        .font(.callout)
        .foregroundStyle(.red)
    }
}

// MARK: - 文言

/// 設定画面の文言。英語を基本にする（暫定 Q-24）。キーは英語の文そのもので、日本語は String Catalog に訳を足す。
private enum SettingsStrings {
    static let triggerKey = String(localized: "Trigger Key:", comment: "Settings: label of the trigger key picker")
    static let hintCharacters = String(
        localized: "Hint Characters:", comment: "Settings: label of the hint characters field"
    )
    static let hintCharactersHelp = String(
        localized: "Letters a–z, at least 2, no duplicates. Default: sadfjklewcmpgh",
        comment: "Settings: help text under the hint characters field"
    )
    static let fontSize = String(localized: "Font Size:", comment: "Settings: label of the font size field")
    static let points = String(localized: "pt", comment: "Settings: unit after the font size (points)")
    static let textColor = String(localized: "Text Color:", comment: "Settings: label of the text color picker")
    static let backgroundColor = String(
        localized: "Background Color:", comment: "Settings: label of the background color picker"
    )
    static let restoreDefaults = String(
        localized: "Restore Defaults", comment: "Settings: button that sets the settings back to their default values"
    )
    static let launchAtLoginSection = String(
        localized: "Startup:", comment: "Settings: label of the row that contains the Open at Login toggle"
    )
    static let launchAtLogin = String(
        localized: "Open at Login", comment: "Settings: toggle that registers Tobi as a login item"
    )
    static let launchAtLoginRequiresApproval = String(
        localized: "Allow Tobi in System Settings > General > Login Items to open it at login.",
        comment: "Settings: shown when the login item needs the user's approval"
    )
    static let openLoginItems = String(
        localized: "Open Login Items Settings…", comment: "Settings: button that opens System Settings > Login Items"
    )
    static let launchAtLoginNotFound = String(
        localized: "Tobi couldn't find its login item. Move Tobi to the Applications folder and try again.",
        comment: "Settings: the login item service was not found (status notFound)"
    )

    static var fontSizeOutOfRange: String {
        let range = LabelAppearance.fontSizeRange
        let lower = Int(range.lowerBound)
        let upper = Int(range.upperBound)
        return String(
            localized: "Enter a size from \(lower) to \(upper) pt. This value was not saved.",
            comment: "Settings: the font size is out of range. Arguments are the minimum and maximum"
        )
    }

    static func name(of key: TriggerKey) -> String {
        switch key {
        case .rightCommand:
            String(localized: "Right Command (⌘)", comment: "Settings: trigger key choice")
        case .rightOption:
            String(localized: "Right Option (⌥)", comment: "Settings: trigger key choice")
        }
    }

    static func message(for error: HintAlphabetError) -> String {
        switch error {
        case .tooFewCharacters:
            String(
                localized: "Use at least 2 characters. This value was not saved.",
                comment: "Settings: the hint characters are too few"
            )
        case .duplicateCharacter(let character):
            String(
                localized: "“\(String(character))” is used more than once. This value was not saved.",
                comment: "Settings: a hint character is duplicated. The argument is the character"
            )
        case .unsupportedCharacter(let character):
            String(
                localized: "“\(String(character))” can't be used. Use letters a–z only. This value was not saved.",
                comment: "Settings: a hint character is not a letter a-z. The argument is the character"
            )
        }
    }

    static func message(for error: RGBAColorError) -> String {
        switch error {
        case .componentOutOfRange:
            String(
                localized: "This color is outside the sRGB range. Choose another color.",
                comment: "Settings: the chosen color could not be saved because a component is out of range"
            )
        // 16 進の文字列の誤りは、保存値の読み込みでだけ起きる（画面の ColorPicker からは来ない）
        case .missingHashPrefix, .invalidLength, .invalidHexDigit:
            String(localized: "This color can't be used.", comment: "Settings: the color could not be saved")
        }
    }
}

// MARK: - プレビュー

#if DEBUG
    /// プレビュー用の保存先。読み込みの結果を固定し、保存は捨てる。
    @MainActor
    private final class PreviewSettingsStore: SettingsStoring {
        private let issues: [SettingsIssue]

        init(issues: [SettingsIssue]) {
            self.issues = issues
        }

        func load() -> SettingsLoadResult {
            SettingsLoadResult(settings: .defaults, issues: issues)
        }

        func save(_ settings: TobiSettings) {}
    }

    /// プレビュー用のログイン時の起動。`SMAppService` を呼ばずに、決めた状態を返す。
    private struct PreviewLaunchAtLoginService: LaunchAtLoginControlling {
        let current: LaunchAtLoginStatus
        let enableFailure: LaunchAtLoginError?

        func status() throws(LaunchAtLoginError) -> LaunchAtLoginStatus { current }

        func enable() throws(LaunchAtLoginError) -> LaunchAtLoginStatus {
            if let enableFailure { throw enableFailure }
            return .enabled
        }

        func disable() throws(LaunchAtLoginError) -> LaunchAtLoginStatus { .notRegistered }

        func openSystemSettingsLoginItems() {}
    }

    @MainActor
    private func previewSettings(issues: [SettingsIssue]) -> SettingsModel {
        SettingsModel(store: PreviewSettingsStore(issues: issues), applyTriggerKey: { _ in })
    }

    @MainActor
    private func previewLaunchAtLogin(
        status: LaunchAtLoginStatus, enableFailure: LaunchAtLoginError?
    ) -> LaunchAtLoginModel {
        let model = LaunchAtLoginModel(
            service: PreviewLaunchAtLoginService(current: status, enableFailure: enableFailure)
        )
        model.refresh()
        if enableFailure != nil {
            model.turnOn()
        }
        return model
    }

    #Preview("既定") {
        SettingsView(
            model: previewSettings(issues: []),
            launchAtLogin: previewLaunchAtLogin(status: .notRegistered, enableFailure: nil),
            sessionID: UUID()
        )
    }

    #Preview("起動時の問題と承認待ち") {
        SettingsView(
            model: previewSettings(
                issues: [
                    .invalidValue(.labelFontSize, reason: "preview"), .invalidValue(.triggerKey, reason: "preview"),
                ]
            ),
            launchAtLogin: previewLaunchAtLogin(status: .requiresApproval, enableFailure: nil),
            sessionID: UUID()
        )
    }

    #Preview("登録の失敗") {
        SettingsView(
            model: previewSettings(issues: []),
            launchAtLogin: previewLaunchAtLogin(
                status: .notRegistered,
                enableFailure: .registerFailed(
                    ServiceManagementFailure(
                        NSError(
                            domain: "SMAppServiceErrorDomain",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
                        )
                    )
                )
            ),
            sessionID: UUID()
        )
    }
#endif
