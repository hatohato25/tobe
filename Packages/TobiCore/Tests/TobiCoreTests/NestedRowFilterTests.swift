import CoreGraphics
import Testing

@testable import TobiCore

private func element(_ id: Int, window: UInt32 = 1, role: String, rect: CGRect) -> CollectedElement {
    CollectedElement(
        id: ElementID(rawValue: id),
        windowID: WindowID(rawValue: window),
        frame: GlobalRect(rect: rect),
        role: role
    )
}

private func ids(_ elements: [CollectedElement]) -> [Int] {
    elements.map(\.id.rawValue)
}

// システム設定のサイドバーの 1 項目（T49 の実機の値）
private let settingsRowRect = CGRect(x: 1358, y: 467, width: 232, height: 46)
private let settingsButtonRect = CGRect(x: 1374, y: 471, width: 123, height: 38)

@Suite("NestedRowFilter: 中に別の要素を持つ行の除外（T49）")
struct NestedRowFilterTests {
    @Test("システム設定のサイドバーの形: 行を除き、中のボタンを残す")
    func settingsSidebar() {
        let elements = [
            element(1, role: "AXRow", rect: settingsRowRect),
            element(2, role: "AXButton", rect: settingsButtonRect),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(ids(output.kept) == [2])
        #expect(output.removedCount == 1)
    }

    @Test("Finder のサイドバーの形（行の中にヒットがない）: 行を残す")
    func finderSidebar() {
        let elements = [
            element(1, role: "AXRow", rect: CGRect(x: 0, y: 100, width: 200, height: 28)),
            element(2, role: "AXRow", rect: CGRect(x: 0, y: 128, width: 200, height: 28)),
            element(3, role: "AXRow", rect: CGRect(x: 0, y: 156, width: 200, height: 28)),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(output.kept == elements)
        #expect(output.removedCount == 0)
    }

    @Test("横に並んだ 2 つの AXTextField（入れ子ではない。Q-31）: 両方を残す")
    func sideBySideTextFields() {
        let elements = [
            element(1, role: "AXTextField", rect: CGRect(x: 300, y: 100, width: 250, height: 20)),
            element(2, role: "AXTextField", rect: CGRect(x: 550, y: 100, width: 120, height: 20)),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(output.kept == elements)
        #expect(output.removedCount == 0)
    }

    @Test("別のウィンドウの要素が行の中に重なっていても、行は除かない")
    func otherWindowIsIgnored() {
        let elements = [
            element(1, window: 1, role: "AXRow", rect: settingsRowRect),
            element(2, window: 2, role: "AXButton", rect: settingsButtonRect),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(output.kept == elements)
        #expect(output.removedCount == 0)
    }

    @Test("行と frame が一致する子は中に入っているものとして扱い、行を除いて子を残す")
    func childWithSameFrame() {
        let elements = [
            element(1, role: "AXRow", rect: settingsRowRect),
            element(2, role: "AXButton", rect: settingsRowRect),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(ids(output.kept) == [2])
        #expect(output.removedCount == 1)
    }

    @Test("frame が一致する 2 つの行は互いを除かない（両方を残す）")
    func rowsWithSameFrame() {
        let elements = [
            element(1, role: "AXRow", rect: settingsRowRect),
            element(2, role: "AXRow", rect: settingsRowRect),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(output.kept == elements)
        #expect(output.removedCount == 0)
    }

    @Test("行の中に行がある場合は外側の行だけを除く")
    func rowInsideRow() {
        let elements = [
            element(1, role: "AXRow", rect: CGRect(x: 0, y: 0, width: 300, height: 100)),
            element(2, role: "AXRow", rect: CGRect(x: 20, y: 10, width: 260, height: 30)),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(ids(output.kept) == [2])
        #expect(output.removedCount == 1)
    }

    @Test("3 段の入れ子（行 → 行 → ボタン）では、中にヒットを持つ行を両方除き、ボタンを残す")
    func threeLevels() {
        let elements = [
            element(1, role: "AXRow", rect: CGRect(x: 0, y: 0, width: 300, height: 100)),
            element(2, role: "AXRow", rect: CGRect(x: 20, y: 10, width: 260, height: 30)),
            element(3, role: "AXButton", rect: CGRect(x: 30, y: 15, width: 50, height: 20)),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(ids(output.kept) == [3])
        #expect(output.removedCount == 2)
    }

    @Test("行からはみ出した要素は中に入っていないので、行を残す")
    func partiallyOverlapping() {
        let elements = [
            element(1, role: "AXRow", rect: settingsRowRect),
            element(2, role: "AXButton", rect: settingsButtonRect.offsetBy(dx: 0, dy: 20)),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(output.kept == elements)
        #expect(output.removedCount == 0)
    }

    @Test("行でない要素は、中に別の要素があっても除かない")
    func nonRowContainer() {
        let elements = [
            element(1, role: "AXGroup", rect: settingsRowRect),
            element(2, role: "AXButton", rect: settingsButtonRect),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(output.kept == elements)
        #expect(output.removedCount == 0)
    }

    @Test("縦に並んだ行のうち、中にボタンを持つ行だけを除き、入力の順序を保つ")
    func mixedRowsKeepOrder() {
        // 入力の順序はばらばらにしておく
        let elements = [
            element(4, role: "AXButton", rect: CGRect(x: 10, y: 52, width: 40, height: 16)),
            element(1, role: "AXRow", rect: CGRect(x: 0, y: 0, width: 200, height: 20)),
            element(3, role: "AXRow", rect: CGRect(x: 0, y: 50, width: 200, height: 20)),
            element(2, role: "AXRow", rect: CGRect(x: 0, y: 25, width: 200, height: 20)),
        ]

        let output = NestedRowFilter.removingNestedRows(elements)

        #expect(ids(output.kept) == [4, 1, 2])
        #expect(output.removedCount == 1)
    }

    @Test("空の入力では空を返す")
    func empty() {
        let output = NestedRowFilter.removingNestedRows([])

        #expect(output.kept.isEmpty)
        #expect(output.removedCount == 0)
    }

    /// 全組を比べると 1 ウィンドウ数百件で重くなるため、行ばかりの 1000 件の所要時間を記録する
    /// （N-1.4 の参考値。合否条件にはしない）。
    @Test("行とボタンが 500 組ずつ（1 ウィンドウ 1000 件）の所要時間を記録する")
    func measureThousandElements() {
        let elements = (0..<500).flatMap { index in
            let y = CGFloat(index) * 50
            return [
                element(index * 2, role: "AXRow", rect: CGRect(x: 0, y: y, width: 232, height: 46)),
                element(index * 2 + 1, role: "AXButton", rect: CGRect(x: 16, y: y + 4, width: 123, height: 38)),
            ]
        }

        let clock = ContinuousClock()
        var removedCount = 0
        let elapsed = clock.measure {
            removedCount = NestedRowFilter.removingNestedRows(elements).removedCount
        }

        Attachment.record("NestedRowFilter 1000 elements: \(elapsed) (N-1.4 reference)", named: "NestedRowFilter.txt")
        #expect(removedCount == 500)
    }
}

@Suite("HintPipeline: 入れ子の行の除外（T49）")
struct HintPipelineNestedRowTests {
    private let window = WindowInfo(
        id: WindowID(rawValue: 1),
        ownerPID: ProcessID(rawValue: 100),
        frame: GlobalRect(rect: CGRect(x: 1000, y: 0, width: 1200, height: 1200)),
        layer: 0,
        zIndex: 0
    )

    @Test("除いた行にはラベルを割り当てず、残った要素にだけ割り当てる。除いた件数は切り捨てと区別する")
    func labelsOnlyRemainingElements() throws {
        let alphabet = try HintAlphabet(validating: "sadf")
        let elements = [
            element(1, role: "AXRow", rect: settingsRowRect),
            element(2, role: "AXButton", rect: settingsButtonRect),
            element(3, role: "AXRow", rect: settingsRowRect.offsetBy(dx: 0, dy: 46)),
        ]
        let input = CollectionResult(windows: [window], elements: elements, diagnostics: [])

        let output = HintPipeline.makeHints(from: input, alphabet: alphabet)

        let expectedLabels = HintLabelGenerator.labels(count: 2, alphabet: alphabet)
        #expect(output.hints.map(\.element.id.rawValue) == [2, 3])
        #expect(output.hints.map(\.label) == expectedLabels)
        #expect(output.removedNestedRowCount == 1)
        #expect(output.truncatedCount == 0)
    }

    @Test("遮蔽で除かれた要素は、行を除く理由にしない（遮蔽の除外 → 入れ子の行の除外の順）")
    func occludedChildDoesNotRemoveRow() {
        // ボタンの中心だけを覆う前面のウィンドウ。行の中心は覆わない
        let cover = WindowInfo(
            id: WindowID(rawValue: 9),
            ownerPID: ProcessID(rawValue: 200),
            frame: GlobalRect(rect: CGRect(x: 1374, y: 471, width: 60, height: 38)),
            layer: 0,
            zIndex: 0
        )
        let back = WindowInfo(
            id: window.id, ownerPID: window.ownerPID, frame: window.frame, layer: 0, zIndex: 1)
        let elements = [
            element(1, role: "AXRow", rect: settingsRowRect),
            element(2, role: "AXButton", rect: CGRect(x: 1380, y: 471, width: 40, height: 38)),
        ]
        let input = CollectionResult(windows: [cover, back], elements: elements, diagnostics: [])

        let output = HintPipeline.makeHints(from: input, alphabet: .vimiumDefault)

        #expect(output.hints.map(\.element.id.rawValue) == [1])
        #expect(output.removedNestedRowCount == 0)
    }
}
