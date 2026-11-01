import CoreGraphics
import Testing

@testable import TobiCore

private func element(_ id: Int, x: Double, y: Double, width: Double = 20, height: Double = 10) -> CollectedElement {
    CollectedElement(
        id: ElementID(rawValue: id),
        windowID: WindowID(rawValue: 1),
        frame: GlobalRect(rect: CGRect(x: x, y: y, width: width, height: height)),
        role: "AXButton"
    )
}

private func ids(_ elements: [CollectedElement]) -> [Int] {
    elements.map(\.id.rawValue)
}

@Suite("ElementSorter（F-3.4、暫定 Q-15）")
struct ElementSorterTests {
    @Test("空の入力は空")
    func empty() {
        #expect(ElementSorter.sorted([]).isEmpty)
    }

    @Test("y の昇順、同じ y なら x の昇順")
    func yThenX() {
        let input = [
            element(1, x: 300, y: 100),
            element(2, x: 10, y: 200),
            element(3, x: 10, y: 100),
            element(4, x: 500, y: 50),
            element(5, x: 200, y: 100),
        ]

        #expect(ids(ElementSorter.sorted(input)) == [4, 3, 5, 1, 2])
    }

    @Test("基準は左上の点（大きさや中心点では並べない）")
    func topLeftAnchor() {
        // 中心点で比べると 2 が先になるが、左上の y は 1 のほうが小さい
        let input = [
            element(2, x: 0, y: 12, width: 10, height: 2),
            element(1, x: 0, y: 10, width: 10, height: 100),
        ]

        #expect(ids(ElementSorter.sorted(input)) == [1, 2])
    }

    @Test("同じ行とみなす許容幅は設けない（y が 0.5 違えば y の順）")
    func noRowTolerance() {
        let input = [
            element(1, x: 0, y: 100.5),
            element(2, x: 500, y: 100),
        ]

        #expect(ids(ElementSorter.sorted(input)) == [2, 1])
    }

    @Test("負の座標（主ディスプレイの上・左のディスプレイ）はグローバル座標のまま先に並ぶ")
    func negativeCoordinates() {
        let input = [
            element(1, x: 100, y: 100),
            element(2, x: -1800, y: 100),
            element(3, x: 100, y: -900),
            element(4, x: -1800, y: -900),
            element(5, x: 0, y: 0),
        ]

        #expect(ids(ElementSorter.sorted(input)) == [4, 3, 5, 2, 1])
    }

    @Test("座標が同じ要素は ElementID の昇順で、入力の順序によらない")
    func stableForSamePosition() {
        let input = [
            element(7, x: 10, y: 10),
            element(3, x: 10, y: 10),
            element(5, x: 10, y: 10, width: 300, height: 300),
            element(1, x: 0, y: 50),
        ]

        let sorted = ids(ElementSorter.sorted(input))

        #expect(sorted == [3, 5, 7, 1])
        #expect(ids(ElementSorter.sorted(input.reversed())) == sorted)
        #expect(ids(ElementSorter.sorted(ElementSorter.sorted(input))) == sorted)
    }
}
