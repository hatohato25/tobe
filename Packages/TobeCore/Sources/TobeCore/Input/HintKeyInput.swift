import Foundation

/// ヒントモードの状態遷移に渡すキー入力（design.md 3.4、5.2）。
///
/// App の `KeyTranslator` が keyCode を文字に変換したうえで `classify(keyCode:translated:flags:isRepeat:)` を呼ぶ（design.md 7.6）。
public enum HintKeyInput: Equatable, Sendable {
    /// ラベルの入力。小文字の `a-z` にそろえ済み（F-4.5）。
    case character(Character)
    /// Backspace（keyCode `0x33`、`kVK_Delete`）。
    case backspace
    /// Esc（keyCode `0x35`、`kVK_Escape`）。⌘ / ⌃ / ⌥ が付いていても Esc として扱う（2026-11-02 決定）。
    case escape
    /// ラベル入力として扱わないキー。理由を持つ（変換できないキーなどを黙って捨てず、ログや検証で区別できるようにする）。
    case ignored(IgnoredReason)

    /// ラベル入力として扱わない理由。入力された文字そのものは持たない（キー入力の内容を持ち回らない）。
    public enum IgnoredReason: Equatable, Sendable {
        /// ⌘ / ⌃ / ⌥ 付き（F-4.5、暫定 Q-8。F-8、F-9 のために空けておく）。
        case modifierCombination
        /// キーリピート（押しっぱなし）による keyDown（F-4.6、暫定 Q-29）。
        case keyRepeat
        /// キーボードレイアウトで文字に変換できなかった（JIS の「英数」「かな」、矢印キー、F キーなど。design.md 7.6）。
        case untranslatable
        /// 文字には変換できたが、英字 `a-z` / `A-Z` ではない（数字、記号など）。
        /// ラベルは `a-z` だけからなるため（D-21）、どのラベルにも一致しない。
        case nonLetterCharacter
    }

    /// `kVK_Escape`
    static let escapeKeyCode: UInt16 = 0x35
    /// `kVK_Delete`（Backspace）
    static let backspaceKeyCode: UInt16 = 0x33

    /// ラベル入力として扱わない修飾キー。Shift は無視する（F-4.5）。
    /// Caps Lock（`alphaShift`）と Fn（`secondaryFn`）も見ない。Caps Lock はトグル状態で、Fn は矢印キーなどで常に立つため。
    static let blockingModifiers: ModifierFlags = [.command, .control, .option]

    /// keyDown を分類する。
    ///
    /// 判定の順序: リピート → Esc → ⌘ / ⌃ / ⌥ → Backspace → 変換結果（Esc と Backspace は keyCode で判定。レイアウトに依存しない）。
    /// リピートを最初に見るのは、Backspace の長押しで連続して消さないため（Q-29）。
    /// Esc を修飾キーより先に見るのは、修飾キーを押したままでも Esc でヒントモードを抜けられるようにするため
    /// （「Esc で終了」は直感的な操作なので、F-4.5 の「修飾キー付きは無視」より優先する。2026-11-02 決定）。
    /// Backspace は修飾キー付きなら無視する（⌥Backspace などを F-8 以降のために空けておく）。
    ///
    /// - Parameters:
    ///   - keyCode: 仮想キーコード。
    ///   - translated: `KeyTranslator` が修飾キーなしで変換した文字。変換できなければ `nil`。
    ///   - flags: keyDown の時点の修飾キーの状態。
    ///   - isRepeat: キーリピートによる keyDown か（`keyboardEventAutorepeat != 0`）。
    public static func classify(
        keyCode: UInt16,
        translated: Character?,
        flags: ModifierFlags,
        isRepeat: Bool
    ) -> HintKeyInput {
        if isRepeat {
            return .ignored(.keyRepeat)
        }
        if keyCode == escapeKeyCode {
            return .escape
        }
        if !flags.isDisjoint(with: blockingModifiers) {
            return .ignored(.modifierCombination)
        }
        if keyCode == backspaceKeyCode {
            return .backspace
        }
        guard let translated else {
            return .ignored(.untranslatable)
        }
        guard let letter = lowercasedASCIILetter(translated) else {
            return .ignored(.nonLetterCharacter)
        }
        return .character(letter)
    }

    /// ASCII の英字なら小文字にそろえて返す。それ以外は `nil`。
    ///
    /// `Character.lowercased()` は使わない。ケルビン記号（U+212A）が `k` になるなど、`a-z` 以外の文字が
    /// `a-z` に化けてしまうため（`HintAlphabet` と同じ方針。D-21）。
    private static func lowercasedASCIILetter(_ character: Character) -> Character? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return nil
        }
        switch scalar.value {
        case 0x61...0x7A:  // a-z
            return character
        case 0x41...0x5A:  // A-Z
            return Character(Unicode.Scalar(UInt8(scalar.value + 0x20)))
        default:
            return nil
        }
    }
}
