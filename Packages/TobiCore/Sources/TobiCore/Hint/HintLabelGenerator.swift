import Foundation

/// ヒントのラベルを生成する（spec.md 4.5）。Vimium の `AlphabetHints.hintStrings` と同じ結果を返す。
public enum HintLabelGenerator {
    /// `count` 個のラベルを返す。どのラベルも他のラベルの接頭辞にならず、長さの差は最大 1。
    ///
    /// ラベル列の i 番目は、`ElementSorter` で並べた i 番目の要素に割り当てる（F-3.4）。
    /// `count` が 0 以下なら空を返す。計算量は O(count × 文字セットの長さ)。
    public static func labels(count: Int, alphabet: HintAlphabet) -> [String] {
        guard count > 0 else { return [] }
        var queue: [String] = [""]
        var offset = 0
        // 未展開の文字列が count 個以上になるまで、先頭から取り出して「文字 + 文字列」を末尾に足す。
        // queue.count == 1 の条件は Vimium と同じ（count == 1 でも 1 回は展開して "" を返さないため）。
        // HintAlphabet は 2 文字以上を保証するので、展開のたびに未展開の数が 1 以上増え、ループは必ず終わる。
        while queue.count - offset < count || queue.count == 1 {
            let hint = queue[offset]
            offset += 1
            for character in alphabet.characters {
                queue.append(String(character) + hint)
            }
        }
        // 未展開の先頭から count 個を取り、ソートしてから各文字列を反転する。
        // 文字は a-z に限られる（D-21）ので、String の比較は JavaScript の sort()（UTF-16 のコード単位順）と一致する
        return queue[offset..<offset + count]
            .sorted()
            .map { String($0.reversed()) }
    }
}
