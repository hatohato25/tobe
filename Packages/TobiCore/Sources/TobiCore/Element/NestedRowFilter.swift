import CoreGraphics

/// 中にクリック可能な要素を持つ行（`AXRow`）を除く（T49 の実機確認で見つけた重複ラベルの対策）。
///
/// システム設定のサイドバーでは、1 つの項目が行（`AXRow` / `AXOutlineRow`）とその中のボタン（`AXButton`）の
/// 2 つのヒットになり、ラベルが 2 つ付く。中の要素を押しても行の項目が選ばれるので、外側の行を除き、中の要素を残す。
///
/// - 行の frame の中に、同じウィンドウ（`windowID` が同じ）の別の要素の frame が完全に入っていれば、その行を除く。
///   判定は `CGRect.contains(_: CGRect)` で、frame が行と一致する要素も「入っている」として扱う（中を残す）。
/// - 別のウィンドウの要素は比べない。前後関係が違い、行の中に重なって見えても、行の中身ではないため。
/// - 行の中に行がある場合は、外側の行だけを除く。内側の行は、それ自体が中に別の要素を持つときだけ除かれる。
/// - frame が一致する 2 つの行は、互いを除く理由にしない（両方を除くと、その項目からラベルが消えるため）。
/// - 中にヒットのない行（Finder のサイドバー）と、入れ子でない要素（Finder のファイル一覧で横に並ぶ 2 つの
///   `AXTextField`。Q-31）には影響しない。
public enum NestedRowFilter {
    /// 判定の対象にする行のロール。`AXOutlineRow` はサブロールなので、ロールはすべて `AXRow` になる（design.md 8.2）。
    public static let rowRole = "AXRow"

    /// 中に別の要素を持つ行を除いた要素と、除いた件数を返す。戻り値は入力の順序を保つ。
    public static func removingNestedRows(
        _ elements: [CollectedElement]
    ) -> (kept: [CollectedElement], removedCount: Int) {
        var removedIndices = Set<Int>()
        for indices in indicesByWindow(elements).values {
            removedIndices.formUnion(rowsContainingOthers(indices, in: elements))
        }
        guard !removedIndices.isEmpty else { return (elements, 0) }
        let kept = elements.indices.filter { !removedIndices.contains($0) }.map { elements[$0] }
        return (kept, removedIndices.count)
    }

    /// 要素の添字をウィンドウごとにまとめる。比べる組をウィンドウの中だけに絞るため。
    private static func indicesByWindow(_ elements: [CollectedElement]) -> [WindowID: [Int]] {
        var result: [WindowID: [Int]] = [:]
        for (index, element) in elements.enumerated() {
            result[element.windowID, default: []].append(index)
        }
        return result
    }

    /// 1 つのウィンドウの要素（`indices`）のうち、中に別の要素を持つ行の添字を返す。
    ///
    /// 1 ウィンドウに数百件あるため、全組を比べずに、上端（minY）の順に並べて二分探索し、行の上端から下端までに
    /// 上端がある要素だけを比べる（行は縦に並ぶので、候補は数件に絞られる）。
    private static func rowsContainingOthers(_ indices: [Int], in elements: [CollectedElement]) -> [Int] {
        guard indices.contains(where: { elements[$0].role == rowRole }) else { return [] }

        let byMinY = indices.sorted { elements[$0].frame.rect.minY < elements[$1].frame.rect.minY }
        var removed: [Int] = []
        for rowIndex in indices where elements[rowIndex].role == rowRole {
            let row = elements[rowIndex]
            let rowRect = row.frame.rect
            var position = firstPosition(in: byMinY, notBelow: rowRect.minY, elements: elements)
            while position < byMinY.count {
                let candidateIndex = byMinY[position]
                let candidate = elements[candidateIndex]
                let candidateRect = candidate.frame.rect
                // 上端が行の下端より下なら、それ以降の要素は行に入らない
                if candidateRect.minY > rowRect.maxY { break }
                position += 1
                guard candidateIndex != rowIndex, rowRect.contains(candidateRect) else { continue }
                if candidate.role == rowRole && candidateRect == rowRect { continue }
                removed.append(rowIndex)
                break
            }
        }
        return removed
    }

    /// `sortedIndices`（minY の昇順）のうち、minY が `minY` 以上になる最初の位置。
    private static func firstPosition(
        in sortedIndices: [Int],
        notBelow minY: CGFloat,
        elements: [CollectedElement]
    ) -> Int {
        var low = 0
        var high = sortedIndices.count
        while low < high {
            let mid = (low + high) / 2
            if elements[sortedIndices[mid]].frame.rect.minY < minY {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
