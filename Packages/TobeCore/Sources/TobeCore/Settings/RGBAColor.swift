import Foundation

/// ラベルの文字色・背景色（S-3、暫定 Q-21: 不透明度を含む RGBA）。
///
/// 各成分は 0...1 の範囲にあることを初期化時に保証する。設定には `#RRGGBBAA` の文字列で保存する（design.md 12.2）。
public struct RGBAColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// 成分（0...1）から作る。設定画面の色の選択（`ColorPicker`）から変換するときに使う。
    ///
    /// 範囲外や NaN を受け付けると、`hexString` で保存できない値が混ざるため拒否する。
    public init(red: Double, green: Double, blue: Double, alpha: Double) throws(RGBAColorError) {
        for (component, value) in [
            (RGBAColorComponent.red, red), (.green, green), (.blue, blue), (.alpha, alpha),
        ] where !(0...1).contains(value) {
            // NaN は `contains` が false になるため、ここで拒否される
            throw .componentOutOfRange(component)
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBBAA` 形式の文字列から作る。16 進の数字は大文字・小文字のどちらも受け付ける。
    ///
    /// 検証は「`#` で始まるか」→「長さ」→「16 進の数字か」の順に行い、最初に見つかった理由で失敗する。
    public init(hex: String) throws(RGBAColorError) {
        guard hex.hasPrefix("#") else { throw .missingHashPrefix }
        let digits = Array(hex.unicodeScalars.dropFirst())
        guard digits.count == 8 else { throw .invalidLength(digitCount: digits.count) }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for index in stride(from: 0, to: 8, by: 2) {
            let high = try Self.hexValue(of: digits[index])
            let low = try Self.hexValue(of: digits[index + 1])
            bytes.append(high << 4 | low)
        }
        self.init(redByte: bytes[0], greenByte: bytes[1], blueByte: bytes[2], alphaByte: bytes[3])
    }

    /// 0...255 の成分から作る。`UInt8 / 255` は必ず 0...1 に入るため検証が要らない。
    /// `init(hex:)` と、既定色の定数（`LabelAppearance.defaults`）で使う。
    init(redByte: UInt8, greenByte: UInt8, blueByte: UInt8, alphaByte: UInt8) {
        self.red = Double(redByte) / 255
        self.green = Double(greenByte) / 255
        self.blue = Double(blueByte) / 255
        self.alpha = Double(alphaByte) / 255
    }

    /// 設定に保存するときの `#RRGGBBAA`（大文字）。
    ///
    /// 各成分を 255 段階に丸めるため、`init(red:green:blue:alpha:)` で作った値は、この文字列を読み直すと
    /// わずかに変わることがある。`init(hex:)` で作った値は同じ文字列に戻る。
    public var hexString: String {
        let bytes = [red, green, blue, alpha].map { UInt8(($0 * 255).rounded()) }
        return "#" + bytes.map { Self.hexDigits($0) }.joined()
    }

    /// ASCII の 16 進の数字だけを受け付ける。
    ///
    /// `Character.hexDigitValue` は全角の数字なども受け付けるため使わない（`#ＦＦ…` を通さないため）。
    private static func hexValue(of scalar: Unicode.Scalar) throws(RGBAColorError) -> UInt8 {
        switch scalar.value {
        case 0x30...0x39: UInt8(scalar.value - 0x30)  // 0-9
        case 0x41...0x46: UInt8(scalar.value - 0x41 + 10)  // A-F
        case 0x61...0x66: UInt8(scalar.value - 0x61 + 10)  // a-f
        default: throw .invalidHexDigit(Character(scalar))
        }
    }

    private static func hexDigits(_ byte: UInt8) -> String {
        let text = String(byte, radix: 16, uppercase: true)
        return byte < 0x10 ? "0" + text : text
    }
}

/// RGBA の成分の名前。`RGBAColorError.componentOutOfRange` で、どの成分が範囲外かを示す。
public enum RGBAColorComponent: String, Equatable, Sendable {
    case red, green, blue, alpha
}

/// `RGBAColor` の検証に失敗した理由。
public enum RGBAColorError: Error, Equatable, Sendable {
    /// 先頭が `#` でない。
    case missingHashPrefix
    /// `#` の後の文字数が 8 でない。
    case invalidLength(digitCount: Int)
    /// 16 進の数字（`0-9`、`A-F`、`a-f`）以外の文字。
    case invalidHexDigit(Character)
    /// 成分が 0...1 の範囲外（NaN を含む）。
    case componentOutOfRange(RGBAColorComponent)
}
