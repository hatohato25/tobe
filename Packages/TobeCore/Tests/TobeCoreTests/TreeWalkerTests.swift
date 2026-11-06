import CoreGraphics
import Testing

@testable import TobeCore

// MARK: - 共通の支援

private let windowRect = FakeNode.windowRect

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

private func hitNames(_ result: WalkResult<String>) -> [String] {
    result.hits.map(\.node)
}

// MARK: - 順序とクリック可能の判定

@Suite("TreeWalker: 順序と判定（design.md 8.4、F-2.8）")
struct TreeWalkerOrderTests {
    @Test("幅優先で辿り、ヒットは浅い階層から並ぶ")
    func breadthFirstOrder() {
        let tree = FakeNode.window([
            FakeNode(
                "split",
                role: "AXSplitGroup",
                frame: windowRect,
                children: [.button("deep1"), .button("deep2")]
            ),
            .button("shallow"),
        ])
        let source = FakeTreeSource(root: tree)

        let result = source.walk()

        #expect(source.readNodeNames == ["window", "split", "shallow", "deep1", "deep2"])
        #expect(hitNames(result) == ["shallow", "deep1", "deep2"])
        #expect(result.stopReason == .completed)
        #expect(result.visitedNodeCount == 5)
        #expect(result.readErrors.isEmpty)
    }

    @Test("ヒットはロールと frame を持つ")
    func hitContents() {
        let frame = rect(30, 40, 50, 20)
        let source = FakeTreeSource(root: .window([FakeNode("link", role: "AXLink", frame: frame)]))

        let result = source.walk()

        #expect(result.hits == [WalkHit(node: "link", role: "AXLink", frame: GlobalRect(rect: frame))])
    }

    @Test("曖昧ロールは AXPress を持つときだけヒットにし、アクション名はそのときだけ読む")
    func ambiguousRoles() {
        let tree = FakeNode.window([
            FakeNode("pressable", role: "AXGroup", frame: rect(0, 0, 50, 50), actionNames: ["AXPress"]),
            FakeNode("plain", role: "AXGroup", frame: rect(0, 0, 50, 50), actionNames: ["AXShowMenu"]),
            .button("button"),
        ])
        let source = FakeTreeSource(root: tree)

        let result = source.walk()

        #expect(Set(hitNames(result)) == ["pressable", "button"])
        let actionReads = source.calls.filter {
            if case .readActionNames = $0 { true } else { false }
        }
        #expect(actionReads == [.readActionNames("pressable"), .readActionNames("plain")])
    }

    @Test("無効な要素と frame のない要素はヒットにしない")
    func excludedByPolicy() {
        let tree = FakeNode.window([
            FakeNode("disabled", role: "AXButton", frame: rect(0, 0, 50, 20), isEnabled: false),
            FakeNode("noFrame", role: "AXButton", frame: nil),
            FakeNode("enabled", role: "AXButton", frame: rect(0, 0, 50, 20), isEnabled: true),
        ])

        let result = FakeTreeSource(root: tree).walk()

        #expect(hitNames(result) == ["enabled"])
    }

    @Test("リーフとして扱うロールは子を辿らない", arguments: TreeWalkerRoles.leafRoles.sorted())
    func leafRoles(role: String) {
        let leaf = FakeNode("leaf", role: role, frame: rect(0, 0, 50, 20), children: [.button("inner")])
        let tree = FakeNode.window([leaf])
        let source = FakeTreeSource(root: tree)

        let result = source.walk()

        #expect(!source.readNodeNames.contains("inner"))
        #expect(!hitNames(result).contains("inner"))
    }

    @Test("リーフ以外のヒット（行など）は子も辿る")
    func clickableContainer() {
        let row = FakeNode("row", role: "AXRow", frame: rect(0, 0, 300, 20), children: [.button("inCell")])
        let tree = FakeNode.window([row])

        let result = FakeTreeSource(root: tree).walk()

        #expect(hitNames(result) == ["row", "inCell"])
    }

    @Test("深さ 50 のノードまで読み、その子は辿らない")
    func depthLimit() {
        // 根（深さ 0）の下に AXGroup を連ね、深さ 50 と 51 にボタンを置く
        var node = FakeNode("button51", role: "AXButton", frame: rect(0, 0, 10, 10))
        node = FakeNode("button50", role: "AXRow", frame: rect(0, 0, 10, 10), children: [node])
        for depth in stride(from: 49, through: 1, by: -1) {
            node = FakeNode("group\(depth)", role: "AXGroup", frame: windowRect, children: [node])
        }
        let source = FakeTreeSource(root: .window([node]))

        let result = source.walk()

        #expect(TreeWalkerLimits.maxDepth == 50)
        #expect(hitNames(result) == ["button50"])
        #expect(source.readNodeNames.count == 51)
        #expect(!source.readNodeNames.contains("button51"))
        #expect(result.stopReason == .completed)
    }

    @Test("IPC のタイムアウトは 50ms と期限までの残りの短いほう")
    func messagingTimeout() {
        let far = FakeTreeSource(root: .window([]), costPerRead: .zero)
        _ = far.walk()
        #expect(far.calls == [.readNode("window", timeout: .milliseconds(50))])

        let near = FakeTreeSource(root: .window([]), costPerRead: .zero)
        _ = near.walk(deadlineAfter: .milliseconds(20))
        #expect(near.calls == [.readNode("window", timeout: .milliseconds(20))])
    }
}

// MARK: - クリップと子の選び方

@Suite("TreeWalker: クリップと枝刈り（design.md 8.4、F-2.9）")
struct TreeWalkerClipTests {
    @Test("クリップと交差しないノードは子孫も含めて辿らない")
    func pruneOutsideClip() {
        let tree = FakeNode.window([
            FakeNode(
                "offscreen",
                role: "AXGroup",
                frame: rect(2000, 0, 100, 100),
                children: [.button("insideButUnderOffscreen")]
            ),
            .button("visible"),
        ])
        let source = FakeTreeSource(root: tree)

        let result = source.walk()

        #expect(hitNames(result) == ["visible"])
        #expect(!source.readNodeNames.contains("insideButUnderOffscreen"))
        // 枝刈りしたノードはアクション名も読まない
        #expect(!source.calls.contains(.readActionNames("offscreen")))
    }

    @Test(
        "面積 0 または frame が取れないコンテナは、枝刈りせず、クリップも狭めずに子を辿る",
        arguments: [CGRect?.some(CGRect(x: 5000, y: 5000, width: 0, height: 0)), nil]
    )
    func containerWithoutArea(frame: CGRect?) {
        let container = FakeNode("container", role: "AXScrollArea", frame: frame, children: [.button("child")])
        let tree = FakeNode.window([container])

        let result = FakeTreeSource(root: tree).walk()

        #expect(hitNames(result) == ["child"])
    }

    @Test(
        "スクロール領域は子のクリップを自分の frame に狭め、それ以外は親のクリップを引き継ぐ",
        arguments: [("AXScrollArea", ["inView"]), ("AXGroup", ["outside", "inView"])]
    )
    func clipNarrowing(role: String, expectedHits: [String]) {
        let children: [FakeNode] = [
            .button("outside", rect(200, 200, 50, 20)), .button("inView", rect(10, 10, 50, 20)),
        ]
        let container = FakeNode("container", role: role, frame: rect(0, 0, 100, 100), children: children)

        let result = FakeTreeSource(root: .window([container])).walk()

        #expect(hitNames(result) == expectedHits)
    }

    @Test("ウィンドウは根のクリップを自分の frame に狭める")
    func windowNarrowsClip() {
        let tree = FakeNode.window([.button("outsideWindow", rect(900, 700, 50, 20))], frame: rect(0, 0, 400, 300))

        let result = FakeTreeSource(root: tree).walk()

        #expect(result.hits.isEmpty)
    }

    @Test("根のクリップと交差しないウィンドウは何も集めない")
    func rootOutsideClip() {
        let source = FakeTreeSource(root: .window([.button("child")]))

        let result = source.walk(clip: rect(2000, 2000, 100, 100))

        #expect(result.hits.isEmpty)
        #expect(source.readNodeNames == ["window"])
    }

    @Test(
        "表・アウトライン・リストは可視の子だけを辿る",
        arguments: [
            ("AXTable", VisibleChildrenAttribute.visibleRows),
            ("AXOutline", .visibleRows),
            ("AXList", .visibleChildren),
        ]
    )
    func visibleChildren(role: String, attribute: VisibleChildrenAttribute) {
        let rows = (1...5).map { FakeNode("row\($0)", role: "AXRow", frame: rect(0, CGFloat($0) * 20, 300, 20)) }
        var table = FakeNode("table", role: role, frame: windowRect, children: rows)
        table.visibleChildNames = ["row2", "row3"]
        let source = FakeTreeSource(root: .window([table]))

        let result = source.walk()

        #expect(hitNames(result) == ["row2", "row3"])
        #expect(source.calls.contains(.readVisibleChildren("table", attribute)))
        #expect(source.readNodeNames == ["window", "table", "row2", "row3"])
    }

    @Test("可視の子の属性がない表は AXChildren を使い、属性がなかったことを数える")
    func visibleChildrenUnsupported() {
        let rows: [FakeNode] = [.button("row1"), .button("row2")]
        let table = FakeNode("table", role: "AXTable", frame: windowRect, children: rows)
        let result = FakeTreeSource(root: .window([table])).walk()

        #expect(hitNames(result) == ["row1", "row2"])
        #expect(result.readErrors == [.attributeUnsupported: 1])
        #expect(result.stopReason == .completed)
    }

    @Test("可視の子が読めなかった表は子を辿らず、件数を数える")
    func visibleChildrenFailed() {
        var table = FakeNode("table", role: "AXTable", frame: windowRect, children: [.button("row1")])
        table.visibleChildrenError = .other(code: -25_200)
        let result = FakeTreeSource(root: .window([table, .button("sibling")])).walk()

        #expect(hitNames(result) == ["sibling"])
        #expect(result.readErrors == [.other(code: -25_200): 1])
    }

    @Test("ウィンドウ・スクロール領域・表以外は AXChildren を使い、可視の子を読まない")
    func plainChildren() {
        let source = FakeTreeSource(root: .window([FakeNode("group", role: "AXGroup", frame: windowRect)]))

        _ = source.walk()

        #expect(
            !source.calls.contains {
                if case .readVisibleChildren = $0 { true } else { false }
            }
        )
    }
}

// MARK: - 打ち切りとエラー

@Suite("TreeWalker: 打ち切りとエラー（design.md 8.4、8.7、F-2.9、N-1.3）")
struct TreeWalkerStopTests {
    @Test("期限を過ぎたら新しい IPC を始めずに打ち切り、それまでのヒットを返す")
    func deadline() {
        // 1 回の読み取りに 10ms。t=30ms に始めた読み取りまでが期限（35ms）の内側
        let source = FakeTreeSource(root: .window(FakeNode.buttons(10)), costPerRead: .milliseconds(10))

        let result = source.walk(deadlineAfter: .milliseconds(35))

        #expect(result.stopReason == .deadline)
        #expect(source.readNodeNames == ["window", "b1", "b2", "b3"])
        #expect(hitNames(result) == ["b1", "b2", "b3"])
        // 期限の直前の読み取りには、期限までの残りだけをタイムアウトに使う
        #expect(source.calls.last == .readNode("b3", timeout: .milliseconds(5)))
    }

    @Test("期限をすでに過ぎていれば何も読まない")
    func deadlineAlreadyPassed() {
        let source = FakeTreeSource(root: .window(FakeNode.buttons(2)))

        let result = source.walk(deadlineAfter: .zero)

        #expect(result.stopReason == .deadline)
        #expect(source.calls.isEmpty)
        #expect(result.visitedNodeCount == 0)
    }

    @Test(
        "ノード数の上限に達したら打ち切り、上限ちょうどなら最後まで辿る",
        arguments: [(3, WalkStopReason.nodeBudget, ["b1", "b2"]), (6, .completed, ["b1", "b2", "b3", "b4", "b5"])]
    )
    func nodeBudget(budget: Int, expectedReason: WalkStopReason, expectedHits: [String]) {
        let result = FakeTreeSource(root: .window(FakeNode.buttons(5))).walk(nodeBudget: budget)

        #expect(result.stopReason == expectedReason)
        #expect(result.visitedNodeCount == budget)
        #expect(hitNames(result) == expectedHits)
    }

    @Test("cannotComplete が 2 回続いたら応答しないとみなして打ち切る")
    func unresponsive() {
        let tree = FakeNode.window([
            FakeNode.failing("slow1", .cannotComplete), FakeNode.failing("slow2", .cannotComplete), .button("after"),
        ])
        let source = FakeTreeSource(root: tree)

        let result = source.walk()

        #expect(result.stopReason == .unresponsive)
        #expect(result.readErrors == [.cannotComplete: 2])
        #expect(!source.readNodeNames.contains("after"))
    }

    @Test("cannotComplete が続かなければ打ち切らない")
    func cannotCompleteNotConsecutive() {
        let tree = FakeNode.window([
            FakeNode.failing("slow1", .cannotComplete), .button("ok"), FakeNode.failing("slow2", .cannotComplete),
            FakeNode.failing("gone", .invalidElement), FakeNode.failing("slow3", .cannotComplete),
        ])

        let result = FakeTreeSource(root: tree).walk()

        #expect(result.stopReason == .completed)
        #expect(result.readErrors == [.cannotComplete: 3, .invalidElement: 1])
        #expect(hitNames(result) == ["ok"])
    }

    @Test(
        "読めなかったノードは子孫ごと飛ばして続け、件数を数える",
        arguments: [AccessibilityReadError.invalidElement, .notImplemented, .attributeUnsupported, .other(code: -1)]
    )
    func skipFailedNode(error: AccessibilityReadError) {
        let tree = FakeNode.window([.failing("broken", error, children: [.button("child")]), .button("sibling")])
        let source = FakeTreeSource(root: tree)

        let result = source.walk()

        #expect(result.stopReason == .completed)
        #expect(hitNames(result) == ["sibling"])
        #expect(!source.readNodeNames.contains("child"))
        #expect(result.readErrors == [error: 1])
    }

    @Test("apiDisabled は走査全体を中止する")
    func apiDisabled() {
        let tree = FakeNode.window([.button("first"), FakeNode.failing("revoked", .apiDisabled), .button("after")])
        let source = FakeTreeSource(root: tree)

        let result = source.walk()

        #expect(result.stopReason == .apiDisabled)
        #expect(hitNames(result) == ["first"])
        #expect(!source.readNodeNames.contains("after"))
    }

    @Test("アクション名の読み取りでの apiDisabled も中止する。その他の失敗はヒットにせず子を辿る")
    func actionNamesErrors() {
        var revoked = FakeNode("revoked", role: "AXGroup", frame: windowRect, actionNames: ["AXPress"])
        revoked.actionNamesError = .apiDisabled
        #expect(FakeTreeSource(root: .window([revoked])).walk().stopReason == .apiDisabled)

        var broken = FakeNode("broken", role: "AXGroup", frame: windowRect, children: [.button("child")])
        broken.actionNames = ["AXPress"]
        broken.actionNamesError = .notImplemented
        let result = FakeTreeSource(root: .window([broken])).walk()
        #expect(result.stopReason == .completed)
        #expect(hitNames(result) == ["child"])
        #expect(result.readErrors == [.notImplemented: 1])
    }

    @Test("キャンセルされたら次の IPC を始めずに打ち切る")
    func cancelled() {
        let source = FakeTreeSource(root: .window(FakeNode.buttons(5)))

        let result = source.walk(isCancelled: { source.calls.count >= 2 })

        #expect(result.stopReason == .cancelled)
        #expect(source.readNodeNames == ["window", "b1"])
        #expect(hitNames(result) == ["b1"])
    }

    @Test("始める前にキャンセルされていれば何も読まない")
    func cancelledBeforeStart() {
        let source = FakeTreeSource(root: .window(FakeNode.buttons(2)))

        let result = source.walk(isCancelled: { true })

        #expect(result.stopReason == .cancelled)
        #expect(source.calls.isEmpty)
    }
}
