import Foundation

/// `CGEventFlags` の生の値を写した OptionSet。
///
/// 値は IOKit の `IOLLEvent.h` の定数と同じ。TobiCore が CoreGraphics に依存しないよう、ビットの意味をここで定義する。
/// App 側は `ModifierFlags(rawValue: event.flags.rawValue)` で変換する。
public struct ModifierFlags: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Caps Lock（`NX_ALPHASHIFTMASK`）。押下状態ではなくトグル状態を表すため、タップ判定には使わない。
    public static let alphaShift = ModifierFlags(rawValue: 0x0001_0000)
    /// `NX_SHIFTMASK`
    public static let shift = ModifierFlags(rawValue: 0x0002_0000)
    /// `NX_CONTROLMASK`
    public static let control = ModifierFlags(rawValue: 0x0004_0000)
    /// `NX_ALTERNATEMASK`
    public static let option = ModifierFlags(rawValue: 0x0008_0000)
    /// `NX_COMMANDMASK`
    public static let command = ModifierFlags(rawValue: 0x0010_0000)
    /// `NX_SECONDARYFNMASK`
    public static let secondaryFn = ModifierFlags(rawValue: 0x0080_0000)

    // 以下はデバイス依存ビット。左右のどちらのキーが押されているかを区別できる（D-5）。
    /// `NX_DEVICELCMDKEYMASK`
    public static let deviceLeftCommand = ModifierFlags(rawValue: 0x0000_0008)
    /// `NX_DEVICERCMDKEYMASK`
    public static let deviceRightCommand = ModifierFlags(rawValue: 0x0000_0010)
    /// `NX_DEVICELALTKEYMASK`
    public static let deviceLeftOption = ModifierFlags(rawValue: 0x0000_0020)
    /// `NX_DEVICERALTKEYMASK`
    public static let deviceRightOption = ModifierFlags(rawValue: 0x0000_0040)
}
