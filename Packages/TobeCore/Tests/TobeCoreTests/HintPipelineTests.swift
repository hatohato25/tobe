import CoreGraphics
import Testing

@testable import TobeCore

private func window(_ id: UInt32, zIndex: Int, rect: CGRect) -> WindowInfo {
    WindowInfo(
        id: WindowID(rawValue: id),
        ownerPID: ProcessID(rawValue: 100),
        frame: GlobalRect(rect: rect),
        layer: 0,
        zIndex: zIndex
    )
}

private func element(_ id: Int, window: UInt32, x: CGFloat, y: CGFloat) -> CollectedElement {
    CollectedElement(
        id: ElementID(rawValue: id),
        windowID: WindowID(rawValue: window),
        frame: GlobalRect(rect: CGRect(x: x, y: y, width: 10, height: 10)),
        role: "AXButton"
    )
}

/// `window` の中に、`firstID` から `count` 個の要素を格子状（1 行 50 個、20pt 間隔）に並べる。
private func grid(count: Int, firstID: Int, window: UInt32, origin: CGPoint) -> [CollectedElement] {
    (0..<count).map { index in
        element(
            firstID + index,
            window: window,
            x: origin.x + CGFloat(index % 50) * 20,
            y: origin.y + CGFloat(index / 50) * 20
        )
    }
}

private func result(windows: [WindowInfo], elements: [CollectedElement]) -> CollectionResult {
    CollectionResult(windows: windows, elements: elements, diagnostics: [])
}

private func ids(_ hints: [Hint]) -> [Int] {
    hints.map(\.element.id.rawValue)
}

// 互いに重ならない 2 枚のウィンドウ。1 が前面
private let frontWindow = window(1, zIndex: 0, rect: CGRect(x: 0, y: 0, width: 1200, height: 1200))
private let backWindow = window(2, zIndex: 1, rect: CGRect(x: 2000, y: 0, width: 1200, height: 1200))

@Suite("HintPipeline: 整列とラベルの割り当て（F-3.4、design.md 1.1）")
struct HintPipelineLabelingTests {
    @Test("空の入力では空を返す")
    func empty() {
        let output = HintPipeline.makeHints(from: result(windows: [], elements: []), alphabet: .vimiumDefault)

        #expect(output == HintPipelineResult(hints: [], truncatedCount: 0, removedNestedRowCount: 0))
    }

    @Test("ウィンドウはあるが要素がない場合も空を返す")
    func noElements() {
        let output = HintPipeline.makeHints(
            from: result(windows: [frontWindow, backWindow], elements: []),
            alphabet: .vimiumDefault
        )

        #expect(output.hints.isEmpty)
        #expect(output.truncatedCount == 0)
    }

    @Test("ラベル列の i 番目が、整列後の i 番目の要素に割り当たる（spec 4.5 の例: sadf・6 個）")
    func labelsFollowSortedOrder() throws {
        let alphabet = try HintAlphabet(validating: "sadf")
        // 入力の順序はばらばらにしておく
        let elements = [
            element(6, window: 1, x: 300, y: 200),
            element(2, window: 1, x: 100, y: 10),
            element(4, window: 1, x: 10, y: 200),
            element(1, window: 1, x: 10, y: 10),
            element(5, window: 1, x: 100, y: 200),
            element(3, window: 1, x: 300, y: 10),
        ]

        let output = HintPipeline.makeHints(
            from: result(windows: [frontWindow], elements: elements), alphabet: alphabet)

        #expect(ids(output.hints) == [1, 2, 3, 4, 5, 6])
        #expect(output.hints.map(\.label) == ["a", "sa", "d", "sd", "f", "ss"])
        #expect(output.truncatedCount == 0)
    }

    @Test("割り当ては HintLabelGenerator と ElementSorter の結果を順に組み合わせたものと一致する", arguments: [1, 14, 15, 200])
    func matchesGeneratorAndSorter(count: Int) {
        let elements = grid(count: count, firstID: 0, window: 1, origin: .zero).reversed()

        let output = HintPipeline.makeHints(
            from: result(windows: [frontWindow], elements: Array(elements)),
            alphabet: .vimiumDefault
        )

        let expectedLabels = HintLabelGenerator.labels(count: count, alphabet: .vimiumDefault)
        let expectedElements = ElementSorter.sorted(Array(elements))
        #expect(output.hints.map(\.label) == expectedLabels)
        #expect(output.hints.map(\.element) == expectedElements)
    }
}

@Suite("HintPipeline: 遮蔽の除外（F-2.11、design.md 8.6）")
struct HintPipelineOcclusionTests {
    @Test("前面のウィンドウに中心が隠れた要素は除き、残った要素だけにラベルを割り当てる")
    func occludedElementsAreRemovedBeforeLabeling() throws {
        let alphabet = try HintAlphabet(validating: "sadf")
        let front = window(1, zIndex: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let back = window(2, zIndex: 1, rect: CGRect(x: 0, y: 0, width: 800, height: 600))
        let elements = [
            element(1, window: 2, x: 10, y: 10),  // 前面のウィンドウに隠れる
            element(2, window: 2, x: 200, y: 10),
            element(3, window: 1, x: 50, y: 50),
            element(4, window: 9, x: 400, y: 400),  // windows にないウィンドウの要素
        ]

        let output = HintPipeline.makeHints(
            from: result(windows: [front, back], elements: elements), alphabet: alphabet)

        #expect(ids(output.hints) == [2, 3])
        #expect(output.hints.map(\.label) == HintLabelGenerator.labels(count: 2, alphabet: alphabet))
        #expect(output.truncatedCount == 0)
    }

    @Test("隠れた要素は上限の件数に数えない（遮蔽の除外 → 上限の順）")
    func occlusionRunsBeforeLimit() {
        let cover = window(3, zIndex: 0, rect: CGRect(x: 0, y: 0, width: 1200, height: 1200))
        let covered = window(1, zIndex: 1, rect: CGRect(x: 0, y: 0, width: 1200, height: 1200))
        let back = window(2, zIndex: 2, rect: CGRect(x: 2000, y: 0, width: 1200, height: 1200))
        // ウィンドウ 1 の 1000 個はすべてウィンドウ 3 に隠れる。見えるのはウィンドウ 2 の 1500 個だけ
        let hidden = grid(count: 1000, firstID: 0, window: 1, origin: .zero)
        let visible = grid(count: HintPipeline.maxHints, firstID: 10_000, window: 2, origin: CGPoint(x: 2000, y: 0))

        let output = HintPipeline.makeHints(
            from: result(windows: [cover, covered, back], elements: hidden + visible),
            alphabet: .vimiumDefault
        )

        #expect(output.hints.count == HintPipeline.maxHints)
        #expect(output.truncatedCount == 0)
        #expect(output.hints.allSatisfy { $0.element.windowID == WindowID(rawValue: 2) })
    }
}

@Suite("HintPipeline: 件数の上限（Q-14、design.md 8.5）")
struct HintPipelineLimitTests {
    @Test("上限は 1500")
    func maxHintsValue() {
        #expect(HintPipeline.maxHints == 1500)
    }

    @Test("ちょうど上限なら切り捨てない")
    func exactlyAtLimit() {
        let elements = grid(count: HintPipeline.maxHints, firstID: 0, window: 1, origin: .zero)

        let output = HintPipeline.makeHints(
            from: result(windows: [frontWindow], elements: elements), alphabet: .vimiumDefault)

        #expect(output.hints.count == HintPipeline.maxHints)
        #expect(output.truncatedCount == 0)
    }

    @Test("上限を 1 件超えると 1 件切り捨て、切り捨てた件数を返す")
    func oneOverLimit() {
        let elements = grid(count: HintPipeline.maxHints + 1, firstID: 0, window: 1, origin: .zero)

        let output = HintPipeline.makeHints(
            from: result(windows: [frontWindow], elements: elements), alphabet: .vimiumDefault)

        #expect(output.hints.count == HintPipeline.maxHints)
        #expect(output.truncatedCount == 1)
        // 同じウィンドウの中では位置順に残すので、最後（右下）の要素が切り捨てられる
        #expect(!ids(output.hints).contains(HintPipeline.maxHints))
    }

    @Test("上限を超えたら前面のウィンドウの要素を優先して残す（入力の順序に依存しない）")
    func frontWindowIsPreferred() {
        let front = grid(count: 1000, firstID: 0, window: 1, origin: .zero)
        let back = grid(count: 1000, firstID: 10_000, window: 2, origin: CGPoint(x: 2000, y: 0))

        // 背面のウィンドウの要素を先に渡す。windows の順序も逆にする
        let output = HintPipeline.makeHints(
            from: result(windows: [backWindow, frontWindow], elements: back.reversed() + front.reversed()),
            alphabet: .vimiumDefault
        )

        #expect(output.hints.count == HintPipeline.maxHints)
        #expect(output.truncatedCount == 500)
        let keptIDs = Set(ids(output.hints))
        // 前面のウィンドウの要素はすべて残る
        #expect(front.allSatisfy { keptIDs.contains($0.id.rawValue) })
        // 背面のウィンドウからは位置順の先頭 500 個（上の 10 行）が残る
        let expectedBack = ElementSorter.sorted(back).prefix(500).map(\.id.rawValue)
        #expect(Set(expectedBack).isSubset(of: keptIDs))
    }

    @Test("上限を適用した後に、残った要素全体を位置順に整列してラベルを割り当てる")
    func sortingRunsAfterLimit() {
        // 背面のウィンドウの要素が画面の上側にあり、前面のウィンドウの要素より先に並ぶ配置
        let front = window(1, zIndex: 0, rect: CGRect(x: 0, y: 1000, width: 1200, height: 1200))
        let back = window(2, zIndex: 1, rect: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let frontElements = grid(count: 1000, firstID: 0, window: 1, origin: CGPoint(x: 0, y: 1000))
        let backElements = grid(count: 1000, firstID: 10_000, window: 2, origin: .zero)

        let output = HintPipeline.makeHints(
            from: result(windows: [front, back], elements: frontElements + backElements),
            alphabet: .vimiumDefault
        )

        let kept = output.hints.map(\.element)
        #expect(kept == ElementSorter.sorted(kept))
        #expect(output.hints.map(\.label) == HintLabelGenerator.labels(count: kept.count, alphabet: .vimiumDefault))
        // 先頭のヒントは、上側にある背面のウィンドウの要素
        #expect(output.hints.first?.element.windowID == WindowID(rawValue: 2))
    }
}

@Suite("HintPipeline: 参考計測（N-1.4）")
struct HintPipelinePerformanceTests {
    /// 要素 1000 個で 5ms 未満が目標（N-1.4）。参考値で合否条件にはしないため、計測値は記録するだけにする
    /// （CI などの遅い環境で失敗させない）。
    @Test("要素 1000 個のパイプラインの所要時間を記録する")
    func measureThousandElements() {
        let front = window(1, zIndex: 0, rect: CGRect(x: 0, y: 0, width: 600, height: 600))
        let back = window(2, zIndex: 1, rect: CGRect(x: 0, y: 0, width: 2000, height: 1200))
        let elements =
            grid(count: 500, firstID: 0, window: 1, origin: .zero)
            + grid(count: 500, firstID: 10_000, window: 2, origin: CGPoint(x: 0, y: 200))
        let input = result(windows: [front, back], elements: elements.reversed())

        let clock = ContinuousClock()
        var output = HintPipelineResult(hints: [], truncatedCount: 0, removedNestedRowCount: 0)
        let elapsed = clock.measure {
            output = HintPipeline.makeHints(from: input, alphabet: .vimiumDefault)
        }

        Attachment.record("HintPipeline 1000 elements: \(elapsed) (target < 5ms, N-1.4)", named: "N-1.4.txt")
        #expect(!output.hints.isEmpty)
    }
}
