import CoreGraphics
import Testing

@testable import TobiCore

@Suite("HintPlacement.clamp（F-3.5）")
struct HintPlacementClampTests {
    static let screenSize = CGSize(width: 1440, height: 900)
    static let labelSize = CGSize(width: 30, height: 20)

    struct ClampCase: Sendable, CustomTestStringConvertible {
        let name: String
        let origin: CGPoint
        let expected: CGPoint
        var testDescription: String { name }
    }

    @Test(
        "画面の四辺からのはみ出しを補正する",
        arguments: [
            ClampCase(name: "画面内はそのまま", origin: CGPoint(x: 100, y: 200), expected: CGPoint(x: 100, y: 200)),
            ClampCase(name: "左にはみ出す", origin: CGPoint(x: -15, y: 200), expected: CGPoint(x: 0, y: 200)),
            ClampCase(name: "上にはみ出す", origin: CGPoint(x: 100, y: -5), expected: CGPoint(x: 100, y: 0)),
            ClampCase(name: "右にはみ出す", origin: CGPoint(x: 1430, y: 200), expected: CGPoint(x: 1410, y: 200)),
            ClampCase(name: "下にはみ出す", origin: CGPoint(x: 100, y: 895), expected: CGPoint(x: 100, y: 880)),
            ClampCase(name: "左上の角", origin: CGPoint(x: -50, y: -50), expected: CGPoint(x: 0, y: 0)),
            ClampCase(name: "右下の角", origin: CGPoint(x: 2000, y: 2000), expected: CGPoint(x: 1410, y: 880)),
            ClampCase(name: "右端にちょうど接する", origin: CGPoint(x: 1410, y: 880), expected: CGPoint(x: 1410, y: 880)),
            ClampCase(name: "原点", origin: .zero, expected: .zero),
        ]
    )
    func clamp(_ testCase: ClampCase) {
        let result = HintPlacement.clamp(
            origin: testCase.origin,
            labelSize: Self.labelSize,
            screenSize: Self.screenSize
        )

        #expect(result == testCase.expected)
    }

    @Test("ラベルが画面より大きい辺は左端・上端に揃える")
    func labelLargerThanScreen() {
        let result = HintPlacement.clamp(
            origin: CGPoint(x: 5, y: 5),
            labelSize: CGSize(width: 200, height: 200),
            screenSize: CGSize(width: 100, height: 100)
        )

        #expect(result == .zero)
    }
}

@Suite("HintPlacement.screen（design.md 9.2）")
struct HintPlacementScreenTests {
    // 主ディスプレイ 1440×900 の右に 2560×1440（上端揃え）、上に 1920×1080 を置いた構成（グローバル座標）
    static let primary = ScreenGeometry(
        id: ScreenID(rawValue: 0),
        frame: GlobalRect(rect: CGRect(x: 0, y: 0, width: 1440, height: 900))
    )
    static let right = ScreenGeometry(
        id: ScreenID(rawValue: 1),
        frame: GlobalRect(rect: CGRect(x: 1440, y: 0, width: 2560, height: 1440))
    )
    static let top = ScreenGeometry(
        id: ScreenID(rawValue: 2),
        frame: GlobalRect(rect: CGRect(x: -240, y: -1080, width: 1920, height: 1080))
    )
    static let screens = [primary, right, top]

    struct ScreenCase: Sendable, CustomTestStringConvertible {
        let name: String
        let element: CGRect
        let expected: ScreenID
        var testDescription: String { name }

        init(_ name: String, _ element: CGRect, screen: Int) {
            self.name = name
            self.element = element
            self.expected = ScreenID(rawValue: screen)
        }
    }

    @Test(
        "要素の左上を含む画面に割り当てる",
        arguments: [
            ScreenCase("主ディスプレイ", CGRect(x: 10, y: 10, width: 50, height: 20), screen: 0),
            ScreenCase("右の画面", CGRect(x: 2000, y: 1000, width: 50, height: 20), screen: 1),
            ScreenCase("上の画面（y が負）", CGRect(x: -100, y: -500, width: 50, height: 20), screen: 2),
            // 中心は右の画面にあるが、左上が主ディスプレイにあるので主ディスプレイ
            ScreenCase("境界をまたぐ要素は左上で決める", CGRect(x: 1400, y: 100, width: 400, height: 20), screen: 0),
            // contains は右端を含まないので、x = 1440 は右の画面
            ScreenCase("隣り合う画面の境界上は右側の画面", CGRect(x: 1440, y: 100, width: 50, height: 20), screen: 1),
            ScreenCase("上下の境界上は下側の画面", CGRect(x: 100, y: 0, width: 50, height: 20), screen: 0),
        ]
    )
    func containing(_ testCase: ScreenCase) {
        let screen = HintPlacement.screen(for: GlobalRect(rect: testCase.element), in: Self.screens)

        #expect(screen?.id == testCase.expected)
    }

    @Test(
        "左上がどの画面にも含まれなければ、中心点が最も近い画面に割り当てる",
        arguments: [
            // 左上は主ディスプレイの左外。中心は主ディスプレイの中
            ScreenCase("左上だけ画面外", CGRect(x: -20, y: 100, width: 100, height: 20), screen: 0),
            // 主ディスプレイの下（y = 900〜1440）には右の画面だけがある。
            // 中心 (1400, 1010) は右の画面から 40、主ディスプレイから 110 離れている
            ScreenCase("主ディスプレイの下の空き領域", CGRect(x: 1380, y: 1000, width: 40, height: 20), screen: 1),
            ScreenCase("すべての画面の左外", CGRect(x: -900, y: 850, width: 40, height: 20), screen: 0),
            ScreenCase("右の画面の右外", CGRect(x: 4100, y: 50, width: 40, height: 20), screen: 1),
            ScreenCase("上の画面のさらに上", CGRect(x: 0, y: -1200, width: 40, height: 20), screen: 2),
        ]
    )
    func nearest(_ testCase: ScreenCase) {
        let screen = HintPlacement.screen(for: GlobalRect(rect: testCase.element), in: Self.screens)

        #expect(screen?.id == testCase.expected)
    }

    @Test("距離が同じなら screens の先頭に近い画面")
    func tieBreaksByOrder() {
        let left = ScreenGeometry(
            id: ScreenID(rawValue: 0), frame: GlobalRect(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let right = ScreenGeometry(
            id: ScreenID(rawValue: 1), frame: GlobalRect(rect: CGRect(x: 200, y: 0, width: 100, height: 100)))
        // 中心 (150, 50) は両方の画面から 50 離れている
        let element = GlobalRect(rect: CGRect(x: 140, y: 40, width: 20, height: 20))

        #expect(HintPlacement.screen(for: element, in: [left, right])?.id == ScreenID(rawValue: 0))
        #expect(HintPlacement.screen(for: element, in: [right, left])?.id == ScreenID(rawValue: 1))
    }

    @Test("画面がなければ nil")
    func noScreens() {
        let element = GlobalRect(rect: CGRect(x: 0, y: 0, width: 10, height: 10))

        #expect(HintPlacement.screen(for: element, in: []) == nil)
    }
}
