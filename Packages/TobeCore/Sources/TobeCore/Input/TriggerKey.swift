import Foundation

/// ヒントモードの起動キー（spec.md 4.4）。設定に保存するため `String` の raw value を持つ。
public enum TriggerKey: String, Codable, CaseIterable, Sendable {
    case rightCommand
    case rightOption

    /// 仮想キーコード（`kVK_RightCommand` / `kVK_RightOption`）。
    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: 0x36
        case .rightOption: 0x3D
        }
    }

    /// 押下中に立つデバイス依存ビット。左右の同種キーを区別して押下 / 解放を判定するために使う（D-5）。
    public var deviceFlag: ModifierFlags {
        switch self {
        case .rightCommand: .deviceRightCommand
        case .rightOption: .deviceRightOption
        }
    }
}
