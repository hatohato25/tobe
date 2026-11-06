import CoreGraphics
import Testing

@testable import TobeCore

@Suite("TreeWalker: メニューバー（design.md 8.1、D-31）")
struct TreeWalkerMenuBarTests {
    /// メニューバーの項目と、その子の閉じたメニュー（面積 0 の AXMenu → AXMenuItem）。
    private static func menuBarItem(_ name: String, x: CGFloat) -> FakeNode {
        let closedMenu = FakeNode(
            "\(name).menu",
            role: "AXMenu",
            frame: .zero,
            children: [
                FakeNode("\(name).item1", role: "AXMenuItem", frame: .zero),
                FakeNode("\(name).item2", role: "AXMenuItem", frame: .zero),
            ]
        )
        return FakeNode(
            name,
            role: "AXMenuBarItem",
            frame: CGRect(x: x, y: 0, width: 40, height: 24),
            children: [closedMenu]
        )
    }

    @Test("AXMenuBarItem はヒットになり、閉じたメニューの子は読まない")
    func menuBarItemIsLeaf() {
        let menuBar = FakeNode(
            "menuBar",
            role: "AXMenuBar",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 24),
            children: [Self.menuBarItem("file", x: 0), Self.menuBarItem("edit", x: 50)]
        )
        let source = FakeTreeSource(root: .window([menuBar]))

        let result = source.walk()

        #expect(result.hits.map(\.node) == ["file", "edit"])
        #expect(result.hits.allSatisfy { $0.role == "AXMenuBarItem" })
        #expect(source.readNodeNames == ["window", "menuBar", "file", "edit"])
        #expect(result.stopReason == .completed)
    }
}
