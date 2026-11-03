import Foundation

/// ラベルの見た目（S-3、暫定 Q-21）。
///
/// フォントサイズが `fontSizeRange` に含まれることを初期化時に保証する。範囲外の値はこの型として存在できないため、
/// 保存（`SettingsStoring.save`）に範囲外のフォントサイズが渡ることはない（S-3.2）。
public struct LabelAppearance: Equatable, Sendable {
    /// フォントサイズの範囲（pt、暫定 Q-21）。
    public static let fontSizeRange: ClosedRange<Double> = 8...32

    /// 既定の見た目: 12pt、文字色 `#302505FF`、背景色 `#FFD752F2`（暫定 Q-21、design.md 12.1）。
    public static let defaults = LabelAppearance(
        validatedFontSize: 12,
        textColor: defaultTextColor,
        backgroundColor: defaultBackgroundColor
    )

    /// 既定の文字色 `#302505FF`。`try!` を使わずに定数を作るため、0...255 の成分で書く。
    private static let defaultTextColor = RGBAColor(
        redByte: 0x30, greenByte: 0x25, blueByte: 0x05, alphaByte: 0xFF
    )
    /// 既定の背景色 `#FFD752F2`。
    private static let defaultBackgroundColor = RGBAColor(
        redByte: 0xFF, greenByte: 0xD7, blueByte: 0x52, alphaByte: 0xF2
    )

    /// フォントサイズ（pt）。`fontSizeRange` に含まれる。
    public let fontSize: Double
    public let textColor: RGBAColor
    public let backgroundColor: RGBAColor

    /// フォントサイズを検証して作る。範囲外（NaN を含む）は `fontSizeOutOfRange` で拒否する（S-3.2）。
    public init(fontSize: Double, textColor: RGBAColor, backgroundColor: RGBAColor) throws(LabelAppearanceError) {
        guard Self.fontSizeRange.contains(fontSize) else {
            throw .fontSizeOutOfRange(fontSize)
        }
        self.init(validatedFontSize: fontSize, textColor: textColor, backgroundColor: backgroundColor)
    }

    /// 検証済みのフォントサイズから作る。`defaults` のように、定数で範囲内であることが明らかな場合だけ使う。
    private init(validatedFontSize: Double, textColor: RGBAColor, backgroundColor: RGBAColor) {
        self.fontSize = validatedFontSize
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }
}

/// `LabelAppearance` の検証に失敗した理由。
public enum LabelAppearanceError: Error, Equatable, Sendable {
    /// フォントサイズが `LabelAppearance.fontSizeRange` の範囲外（NaN を含む）。
    case fontSizeOutOfRange(Double)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.fontSizeOutOfRange(let left), .fontSizeOutOfRange(let right)):
            // NaN 同士も同じ理由として扱う（Double の == では NaN が自分自身と等しくならないため）
            left == right || (left.isNaN && right.isNaN)
        }
    }
}
