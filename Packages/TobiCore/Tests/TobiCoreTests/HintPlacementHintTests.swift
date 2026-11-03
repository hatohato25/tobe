import CoreGraphics
import Testing

@testable import TobiCore

private func hint(_ id: Int, label: String, frame: CGRect) -> Hint {
    Hint(
        label: label,
        element: CollectedElement(
            id: ElementID(rawValue: id),
            windowID: WindowID(rawValue: 1),
            frame: GlobalRect(rect: frame),
            role: "AXButton"
        )
    )
}

@Suite("HintPlacement.place（design.md 9.2）")
struct HintPlacementPlaceTests {
    // 主ディスプレイ 1440×900 と、その左（x が負）に 2560×1440 の副ディスプレイ
    static let primary = ScreenGeometry(
        id: ScreenID(rawValue: 0),
        frame: GlobalRect(rect: CGRect(x: 0, y: 0, width: 1440, height: 900))
    )
    static let left = ScreenGeometry(
        id: ScreenID(rawValue: 1),
        frame: GlobalRect(rect: CGRect(x: -2560, y: -540, width: 2560, height: 1440))
    )
    static let screens = [primary, left]

    @Test("要素の左上を含む画面に割り当て、anchor は画面ローカル座標の左上")
    func assignsContainingScreen() {
        let hints = [
            hint(0, label: "a", frame: CGRect(x: 100, y: 200, width: 50, height: 20)),
            hint(1, label: "sa", frame: CGRect(x: -2000, y: -500, width: 50, height: 20)),
        ]

        let placements = HintPlacement.place(hints, screens: Self.screens)

        #expect(
            placements == [
                HintPlacement(
                    elementID: ElementID(rawValue: 0),
                    label: "a",
                    screenID: Self.primary.id,
                    anchor: CGPoint(x: 100, y: 200)
                ),
                HintPlacement(
                    elementID: ElementID(rawValue: 1),
                    label: "sa",
                    screenID: Self.left.id,
                    anchor: CGPoint(x: 560, y: 40)
                ),
            ]
        )
    }

    @Test("どの画面にも含まれなければ最寄りの画面。anchor は clamp 前の値")
    func assignsNearestScreenWithoutClamp() {
        // 主ディスプレイの右の外側。最寄りは主ディスプレイ
        let hints = [hint(0, label: "a", frame: CGRect(x: 1500, y: 100, width: 40, height: 20))]

        let placements = HintPlacement.place(hints, screens: Self.screens)

        #expect(placements.map(\.screenID) == [Self.primary.id])
        #expect(placements.map(\.anchor) == [CGPoint(x: 1500, y: 100)])
    }

    @Test("入力の順序と件数を保つ")
    func preservesOrder() {
        let hints = (0..<5).map { index in
            hint(index, label: "l\(index)", frame: CGRect(x: Double(index) * 100, y: 10, width: 10, height: 10))
        }

        let placements = HintPlacement.place(hints, screens: Self.screens)

        #expect(placements.map(\.elementID) == hints.map(\.element.id))
        #expect(placements.map(\.label) == hints.map(\.label))
    }

    @Test("ヒントが空なら空")
    func emptyHints() {
        #expect(HintPlacement.place([], screens: Self.screens).isEmpty)
    }

    @Test("画面が空なら空")
    func emptyScreens() {
        let hints = [hint(0, label: "a", frame: CGRect(x: 0, y: 0, width: 10, height: 10))]

        #expect(HintPlacement.place(hints, screens: []).isEmpty)
    }
}
