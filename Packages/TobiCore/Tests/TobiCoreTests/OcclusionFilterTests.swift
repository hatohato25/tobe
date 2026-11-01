import CoreGraphics
import Testing

@testable import TobiCore

// kCGNormalWindowLevel / kCGMainMenuWindowLevel / kCGPopUpMenuWindowLevel の値。
// TobiCore は CGWindowLevel の定数（OS 依存の API の一部）を使わないため、値を直接書く。
private let normalLayer = 0
private let mainMenuLayer = 24
private let popUpMenuLayer = 101

private func window(_ id: UInt32, zIndex: Int, rect: CGRect, layer: Int = normalLayer) -> WindowInfo {
    WindowInfo(
        id: WindowID(rawValue: id),
        ownerPID: ProcessID(rawValue: 100),
        frame: GlobalRect(rect: rect),
        layer: layer,
        zIndex: zIndex
    )
}

private func element(_ id: Int, window: UInt32, rect: CGRect, role: String = "AXButton") -> CollectedElement {
    CollectedElement(
        id: ElementID(rawValue: id),
        windowID: WindowID(rawValue: window),
        frame: GlobalRect(rect: rect),
        role: role
    )
}

/// 中心点が `center` になる 2x2 の要素。
private func element(_ id: Int, window: UInt32, center: CGPoint) -> CollectedElement {
    element(id, window: window, rect: CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2))
}

private func ids(_ elements: [CollectedElement]) -> [Int] {
    elements.map(\.id.rawValue)
}

@Suite("OcclusionFilter.visibleElements（F-2.11、Q-12、design.md 8.6）")
struct OcclusionVisibleElementsTests {
    // 背面のウィンドウ 2 の上に、前面のウィンドウ 1 が (100, 100)〜(300, 300) で重なっている
    private let front = window(1, zIndex: 0, rect: CGRect(x: 100, y: 100, width: 200, height: 200))
    private let back = window(2, zIndex: 1, rect: CGRect(x: 0, y: 0, width: 800, height: 600))

    @Test("空の入力は空")
    func empty() {
        #expect(OcclusionFilter.visibleElements([], windows: [front, back]).isEmpty)
    }

    @Test("中心点が前面のウィンドウに含まれる要素だけを除外する")
    func centerInsideFrontWindow() {
        let elements = [
            element(1, window: 2, center: CGPoint(x: 200, y: 200)),  // 隠れる
            element(2, window: 2, center: CGPoint(x: 50, y: 50)),  // 見える
            element(3, window: 1, center: CGPoint(x: 200, y: 200)),  // 前面のウィンドウ自身の要素
        ]

        #expect(ids(OcclusionFilter.visibleElements(elements, windows: [front, back])) == [2, 3])
    }

    @Test("一部が隠れていても中心点が見えていれば残す。中心点が隠れていれば一部が見えていても除外する")
    func partialOverlap() {
        let elements = [
            // (60, 60)〜(140, 140)。中心 (100, 100) は前面のウィンドウの左上の角
            element(1, window: 2, rect: CGRect(x: 60, y: 60, width: 80, height: 80)),
            // (40, 150)〜(140, 170)。中心 (90, 160) は前面のウィンドウの外
            element(2, window: 2, rect: CGRect(x: 40, y: 150, width: 100, height: 20)),
        ]

        #expect(ids(OcclusionFilter.visibleElements(elements, windows: [front, back])) == [2])
    }

    struct EdgeCase: Sendable, CustomTestStringConvertible {
        let center: CGPoint
        let isHidden: Bool
        let testDescription: String
    }

    @Test(
        "前面のウィンドウの境界: 左端・上端は含み、右端・下端は含まない（CGRect.contains）",
        arguments: [
            EdgeCase(center: CGPoint(x: 100, y: 200), isHidden: true, testDescription: "左端 x=100"),
            EdgeCase(center: CGPoint(x: 200, y: 100), isHidden: true, testDescription: "上端 y=100"),
            EdgeCase(center: CGPoint(x: 100, y: 100), isHidden: true, testDescription: "左上の角"),
            EdgeCase(center: CGPoint(x: 300, y: 200), isHidden: false, testDescription: "右端 x=300"),
            EdgeCase(center: CGPoint(x: 200, y: 300), isHidden: false, testDescription: "下端 y=300"),
            EdgeCase(center: CGPoint(x: 300, y: 300), isHidden: false, testDescription: "右下の角"),
            EdgeCase(center: CGPoint(x: 299.5, y: 299.5), isHidden: true, testDescription: "右下の角の内側"),
            EdgeCase(center: CGPoint(x: 99.5, y: 200), isHidden: false, testDescription: "左端の外側"),
            EdgeCase(center: CGPoint(x: 200, y: 99.5), isHidden: false, testDescription: "上端の外側"),
        ]
    )
    func boundary(_ testCase: EdgeCase) {
        let target = element(1, window: 2, center: testCase.center)

        let visible = OcclusionFilter.visibleElements([target], windows: [front, back])

        #expect(visible.isEmpty == testCase.isHidden)
    }

    @Test("背面のウィンドウは前面の要素を隠さない")
    func backWindowDoesNotHideFront() {
        // ウィンドウ 2 はウィンドウ 1 を完全に含むが、背面にある
        let target = element(1, window: 1, center: CGPoint(x: 200, y: 200))

        #expect(ids(OcclusionFilter.visibleElements([target], windows: [front, back])) == [1])
    }

    @Test("windows の並び順によらず zIndex で前後を決める")
    func windowOrderIndependent() {
        let target = element(1, window: 2, center: CGPoint(x: 200, y: 200))

        #expect(OcclusionFilter.visibleElements([target], windows: [back, front]).isEmpty)
    }

    @Test("3 枚のうち中間のウィンドウの要素は、最前面のウィンドウだけで判定する")
    func middleWindow() {
        let topmost = window(10, zIndex: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let middle = window(11, zIndex: 1, rect: CGRect(x: 50, y: 50, width: 200, height: 200))
        let bottom = window(12, zIndex: 2, rect: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let elements = [
            element(1, window: 11, center: CGPoint(x: 75, y: 75)),  // 最前面に隠れる
            element(2, window: 11, center: CGPoint(x: 150, y: 150)),  // 見える
            element(3, window: 12, center: CGPoint(x: 150, y: 150)),  // 中間に隠れる
            element(4, window: 12, center: CGPoint(x: 500, y: 500)),  // 見える
        ]

        let visible = OcclusionFilter.visibleElements(elements, windows: [topmost, middle, bottom])

        #expect(ids(visible) == [2, 4])
    }

    @Test("入力の順序を保つ")
    func preservesOrder() {
        let elements = [
            element(9, window: 2, center: CGPoint(x: 700, y: 500)),
            element(1, window: 2, center: CGPoint(x: 10, y: 10)),
            element(5, window: 1, center: CGPoint(x: 150, y: 150)),
        ]

        #expect(ids(OcclusionFilter.visibleElements(elements, windows: [front, back])) == [9, 1, 5])
    }

    @Test("要素のウィンドウが windows にない場合は除外する")
    func unknownWindow() {
        let target = element(1, window: 99, center: CGPoint(x: 700, y: 500))

        #expect(OcclusionFilter.visibleElements([target], windows: [front, back]).isEmpty)
    }

    @Test("面積 0 の前面のウィンドウは何も隠さない")
    func zeroAreaFrontWindow() {
        let empty = window(3, zIndex: 0, rect: CGRect(x: 200, y: 200, width: 0, height: 0))
        let target = element(1, window: 2, center: CGPoint(x: 200, y: 200))

        #expect(ids(OcclusionFilter.visibleElements([target], windows: [empty, back])) == [1])
    }

    @Test("負の座標（主ディスプレイの左・上のディスプレイ）でも判定する")
    func negativeCoordinates() {
        let frontLeft = window(1, zIndex: 0, rect: CGRect(x: -1500, y: -800, width: 400, height: 300))
        let backLeft = window(2, zIndex: 1, rect: CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
        let elements = [
            element(1, window: 2, center: CGPoint(x: -1300, y: -600)),  // 隠れる
            element(2, window: 2, center: CGPoint(x: -1700, y: -600)),  // 見える
            element(3, window: 2, center: CGPoint(x: -1100, y: -600)),  // 右端（含まない）
        ]

        #expect(ids(OcclusionFilter.visibleElements(elements, windows: [frontLeft, backLeft])) == [2, 3])
    }
}

@Suite("OcclusionFilter のメニューバーと開いているメニュー（Q-12(b)、design.md 8.1・8.6）")
struct OcclusionMenuTests {
    // CGWindowList の並び: 開いているメニュー → メニューバー → 通常のウィンドウ
    private let menu = window(30, zIndex: 0, rect: CGRect(x: 40, y: 24, width: 220, height: 300), layer: popUpMenuLayer)
    private let menuBar = window(20, zIndex: 1, rect: CGRect(x: 0, y: 0, width: 1440, height: 24), layer: mainMenuLayer)
    private let document = window(1, zIndex: 2, rect: CGRect(x: 0, y: 0, width: 1440, height: 900))

    @Test("開いているメニューより背面の要素は除外し、メニューの項目は残す")
    func openMenuHidesBehind() {
        let elements = [
            element(1, window: 30, rect: CGRect(x: 40, y: 30, width: 220, height: 20), role: "AXMenuItem"),
            element(2, window: 1, center: CGPoint(x: 100, y: 100)),  // メニューの下
            element(3, window: 1, center: CGPoint(x: 600, y: 100)),  // メニューの外
        ]

        let visible = OcclusionFilter.visibleElements(elements, windows: [menu, menuBar, document])

        #expect(ids(visible) == [1, 3])
    }

    @Test("メニューバーの項目は、メニューバーより前面のもの（開いているメニュー）だけで判定する")
    func menuBarItems() {
        let elements = [
            // メニューバーの下にある通常のウィンドウ（zIndex 2）とは重なるが、背面なので残る
            element(1, window: 20, rect: CGRect(x: 10, y: 0, width: 30, height: 24), role: "AXMenuBarItem"),
            element(2, window: 20, rect: CGRect(x: 50, y: 0, width: 40, height: 24), role: "AXMenuBarItem"),
        ]

        // メニューの上端は y=24 で、メニューバーの項目の中心 y=12 は含まれない
        #expect(ids(OcclusionFilter.visibleElements(elements, windows: [menu, menuBar, document])) == [1, 2])
    }

    @Test("メニューバーより背面の通常のウィンドウで、メニューバーに重なる要素は除外する")
    func menuBarHidesWindowContent() {
        let target = element(1, window: 1, center: CGPoint(x: 500, y: 10))

        #expect(OcclusionFilter.visibleElements([target], windows: [menu, menuBar, document]).isEmpty)
    }

    @Test("メニューバーに重なるメニューがメニューバーの項目を隠す")
    func menuOverMenuBar() {
        let overlappingMenu = window(
            31,
            zIndex: 0,
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            layer: popUpMenuLayer
        )
        let target = element(1, window: 20, rect: CGRect(x: 10, y: 0, width: 30, height: 24), role: "AXMenuBarItem")

        #expect(OcclusionFilter.visibleElements([target], windows: [overlappingMenu, menuBar, document]).isEmpty)
    }
}

@Suite("OcclusionFilter.isFullyCovered（design.md 8.1 の手順 3）")
struct OcclusionFullyCoveredTests {
    private let target = window(2, zIndex: 1, rect: CGRect(x: 100, y: 100, width: 400, height: 300))

    @Test("前面の 1 枚に完全に覆われていれば true")
    func coveredByOne() {
        let cover = window(1, zIndex: 0, rect: CGRect(x: 50, y: 50, width: 600, height: 500))

        #expect(OcclusionFilter.isFullyCovered(target, by: [cover, target]))
    }

    @Test("前面のウィンドウと同じ frame でも true（矩形の包含は境界を含む）")
    func sameFrame() {
        let cover = window(1, zIndex: 0, rect: CGRect(x: 100, y: 100, width: 400, height: 300))

        #expect(OcclusionFilter.isFullyCovered(target, by: [cover, target]))
    }

    @Test("1pt でもはみ出していれば false")
    func partiallyCovered() {
        let covers = [
            window(1, zIndex: 0, rect: CGRect(x: 101, y: 100, width: 400, height: 300)),
            window(3, zIndex: 0, rect: CGRect(x: 100, y: 100, width: 399, height: 300)),
            window(4, zIndex: 0, rect: CGRect(x: 100, y: 99, width: 400, height: 300)),
        ]

        for cover in covers {
            #expect(!OcclusionFilter.isFullyCovered(target, by: [cover, target]))
        }
    }

    @Test("背面のウィンドウに含まれていても false")
    func coveredByBackWindow() {
        let behind = window(3, zIndex: 2, rect: CGRect(x: 0, y: 0, width: 2000, height: 2000))

        #expect(!OcclusionFilter.isFullyCovered(target, by: [target, behind]))
    }

    @Test("自分自身では覆われない")
    func notCoveredBySelf() {
        #expect(!OcclusionFilter.isFullyCovered(target, by: [target]))
        #expect(!OcclusionFilter.isFullyCovered(target, by: []))
    }

    @Test("複数のウィンドウを合わせて覆われていても false（1 枚で覆う場合だけを判定する）")
    func coveredByUnion() {
        let left = window(1, zIndex: 0, rect: CGRect(x: 0, y: 0, width: 300, height: 1000))
        let right = window(3, zIndex: 0, rect: CGRect(x: 300, y: 0, width: 1000, height: 1000))

        #expect(!OcclusionFilter.isFullyCovered(target, by: [left, right, target]))
    }

    @Test("メニューバーなどレイヤーが 0 以外のウィンドウでも覆えば true")
    func coveredByNonZeroLayer() {
        let small = window(5, zIndex: 3, rect: CGRect(x: 10, y: 2, width: 100, height: 20))
        let menuBar = window(20, zIndex: 0, rect: CGRect(x: 0, y: 0, width: 1440, height: 24), layer: mainMenuLayer)

        #expect(OcclusionFilter.isFullyCovered(small, by: [menuBar, small]))
    }

    @Test("面積 0 のウィンドウは何も覆わない")
    func zeroAreaCover() {
        let zero = window(1, zIndex: 0, rect: CGRect(x: 100, y: 100, width: 0, height: 0))
        let zeroTarget = window(2, zIndex: 1, rect: CGRect(x: 100, y: 100, width: 0, height: 0))

        #expect(!OcclusionFilter.isFullyCovered(zeroTarget, by: [zero, zeroTarget]))
    }

    @Test("負の座標でも判定する")
    func negativeCoordinates() {
        let cover = window(1, zIndex: 0, rect: CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
        let inside = window(2, zIndex: 1, rect: CGRect(x: -1500, y: -800, width: 400, height: 300))
        let crossing = window(3, zIndex: 1, rect: CGRect(x: -200, y: -300, width: 400, height: 300))

        #expect(OcclusionFilter.isFullyCovered(inside, by: [cover, inside]))
        #expect(!OcclusionFilter.isFullyCovered(crossing, by: [cover, crossing]))
    }
}
