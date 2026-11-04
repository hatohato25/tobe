import CoreGraphics

/// `HintPipeline.makeHints(from:alphabet:)` の結果。
public struct HintPipelineResult: Equatable, Sendable {
    /// 位置順（`ElementSorter`）に並んだヒント。i 番目のラベルは `HintLabelGenerator` のラベル列の i 番目。
    public let hints: [Hint]
    /// 件数の上限（`HintPipeline.maxHints`）を超えたために切り捨てた要素の数。0 なら切り捨てていない。
    /// 黙って捨てないため、呼び出し側がログに出す。
    public let truncatedCount: Int
    /// 中に別の要素を持つ行として除いた要素の数（`NestedRowFilter`）。`truncatedCount` には含めない。
    /// 中の要素にラベルが付くので取りこぼしではなく、ログには出さない。
    public let removedNestedRowCount: Int

    public init(hints: [Hint], truncatedCount: Int, removedNestedRowCount: Int) {
        self.hints = hints
        self.truncatedCount = truncatedCount
        self.removedNestedRowCount = removedNestedRowCount
    }
}

/// 収集結果からヒントを作る（design.md 1.1 の手順 4、8.5、8.6）。
public enum HintPipeline {
    /// ヒントの件数の上限（暫定 Q-14。性能確保のための内部値で、設定項目にはしない）。
    public static let maxHints = 1500

    /// 遮蔽の除外 → 入れ子の行の除外 → 前面のウィンドウを優先して上限まで残す → 位置順に整列 → ラベル割り当て、
    /// の順に処理する。
    ///
    /// - 遮蔽の除外は `OcclusionFilter.visibleElements` に任せる。alpha は見ないため、透明なウィンドウと
    ///   Tobi 自身のウィンドウは、呼び出し側（App）が `result.windows` から除いて渡す前提。
    ///   `result.windows` にないウィンドウの要素は除かれる。
    /// - 入れ子の行の除外は `NestedRowFilter` に任せる。遮蔽の除外の後に行うのは、隠れて除かれた要素を理由に
    ///   行を除くと、行も中の要素もラベルを失うため。上限の前に行うのは、除く行を上限の件数に数えないため。
    /// - 上限を超えたら、ウィンドウの `zIndex` が小さい（前面の）ウィンドウの要素から残す（design.md 8.5）。
    ///   同じウィンドウの中では位置順（`ElementSorter` の順）に残す。収集はアプリ単位で並列に行い、
    ///   入力の順序は実行ごとに変わりうるため、入力の順序には依存させない。
    /// - 整列は上限を適用した後に行う。ラベルは残った要素の数だけ生成し、整列後の i 番目の要素に
    ///   i 番目のラベルを割り当てる（F-3.4）。
    /// - 要素が 0 件なら空の結果を返す（0 件の扱い（Q-11）は呼び出し側が決める）。
    public static func makeHints(from result: CollectionResult, alphabet: HintAlphabet) -> HintPipelineResult {
        let visible = OcclusionFilter.visibleElements(result.elements, windows: result.windows)
        let (withoutNestedRows, removedNestedRowCount) = NestedRowFilter.removingNestedRows(visible)
        let (kept, truncatedCount) = limitPreferringFrontWindows(withoutNestedRows, windows: result.windows)
        let sorted = ElementSorter.sorted(kept)
        let labels = HintLabelGenerator.labels(count: sorted.count, alphabet: alphabet)
        let hints = zip(labels, sorted).map { Hint(label: $0, element: $1) }
        return HintPipelineResult(
            hints: hints,
            truncatedCount: truncatedCount,
            removedNestedRowCount: removedNestedRowCount
        )
    }

    /// `maxHints` 件を超えていれば、前面のウィンドウの要素を優先して `maxHints` 件まで残す。
    private static func limitPreferringFrontWindows(
        _ elements: [CollectedElement],
        windows: [WindowInfo]
    ) -> (kept: [CollectedElement], truncatedCount: Int) {
        guard elements.count > maxHints else { return (elements, 0) }

        // 同じ ID のウィンドウが重複して渡された場合は、OcclusionFilter と同じく最も前面の zIndex を使う
        var zIndexByWindow: [WindowID: Int] = [:]
        for window in windows {
            if let current = zIndexByWindow[window.id], current <= window.zIndex { continue }
            zIndexByWindow[window.id] = window.zIndex
        }

        // OcclusionFilter は windows にないウィンドウの要素を除外するので、ここに来る要素のウィンドウは必ず windows にある。
        // 見つからなければ呼び出し順の誤り（遮蔽の除外を通していない）なので、既定値で埋めずに止める（暗黙のフォールバックの禁止）
        let keyed = ElementSorter.sorted(elements).enumerated().map { offset, element in
            guard let zIndex = zIndexByWindow[element.windowID] else {
                preconditionFailure("要素 \(element.id.rawValue) のウィンドウ \(element.windowID.rawValue) が windows にない")
            }
            return (element: element, zIndex: zIndex, offset: offset)
        }
        let ordered = keyed.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.offset < rhs.offset
        }
        let kept = ordered.prefix(maxHints).map(\.element)
        return (Array(kept), elements.count - kept.count)
    }
}
