import Foundation

/// ヒントのラベルに使う文字セット（spec.md 4.5、S-2）。
///
/// 小文字の `a-z` だけからなり、重複がなく、2 文字以上であることを初期化時に保証する。
/// 1 文字の文字セットでは `HintLabelGenerator` のループが終わらないため、この不変条件を型で守る（design.md 6.1）。
public struct HintAlphabet: Equatable, Sendable {
    /// 小文字、重複なし、2 文字以上。並びは入力の順を保つ（ラベル生成の結果が並びに依存するため）。
    public let characters: [Character]

    /// Vimium の既定値と同じ文字セット（S-2.1）。
    public static let vimiumDefault = HintAlphabet(validatedCharacters: Array("sadfjklewcmpgh"))

    /// 文字列を検証して文字セットを作る。英大文字は小文字にそろえる（S-2.3、暫定 Q-20）。
    ///
    /// 検証は「使えない文字」→「重複」→「文字数」の順に行い、最初に見つかった理由で失敗する。
    /// 大文字を小文字にそろえてから重複を調べるため、`"aA"` は重複として拒否される。
    public init(validating string: String) throws(HintAlphabetError) {
        var normalized: [Character] = []
        var seen: Set<Character> = []
        for character in string {
            let lowercased = try Self.normalize(character)
            guard seen.insert(lowercased).inserted else {
                throw .duplicateCharacter(lowercased)
            }
            normalized.append(lowercased)
        }
        guard normalized.count >= 2 else {
            throw .tooFewCharacters(count: normalized.count)
        }
        self.init(validatedCharacters: normalized)
    }

    /// 検証済みの文字の並びから作る。`vimiumDefault` のように、定数で不変条件を満たすことが明らかな場合だけ使う。
    private init(validatedCharacters: [Character]) {
        self.characters = validatedCharacters
    }

    /// 設定に保存するときの文字列表現。
    public var stringValue: String {
        String(characters)
    }

    /// ASCII の英字だけを受け付け、小文字にそろえる。
    ///
    /// `Character.lowercased()` は使わない。Unicode の小文字化では、ケルビン記号（U+212A）が `k` になるなど、
    /// `a-z` 以外の文字が `a-z` に化けて受け付けられてしまうため（D-21: ソート順を Vimium と確実に一致させる）。
    private static func normalize(_ character: Character) throws(HintAlphabetError) -> Character {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            throw .unsupportedCharacter(character)
        }
        switch scalar.value {
        case 0x61...0x7A:  // a-z
            return character
        case 0x41...0x5A:  // A-Z
            return Character(Unicode.Scalar(UInt8(scalar.value + 0x20)))
        default:
            throw .unsupportedCharacter(character)
        }
    }
}

/// `HintAlphabet` の検証に失敗した理由。設定画面で理由を表示するために使う（S-2.2）。
public enum HintAlphabetError: Error, Equatable, Sendable {
    /// 2 文字未満。`count` は正規化後の文字数。
    case tooFewCharacters(count: Int)
    /// 同じ文字が 2 回以上現れた（小文字にそろえた後の文字）。
    case duplicateCharacter(Character)
    /// 英字 `a-z` / `A-Z` 以外の文字（暫定 Q-20）。入力されたままの文字を持つ。
    case unsupportedCharacter(Character)
}
