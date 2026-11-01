import CoreGraphics
import Testing

@testable import TobiCore

@Suite("CoordinateConverter（design.md 9.1, 9.2 / N-5.1）")
struct CoordinateConverterTests {
    /// 主ディスプレイと副ディスプレイ 1 枚の配置。AppKit の frame と、期待するグローバル座標の frame を持つ。
    struct Arrangement: Sendable, CustomTestStringConvertible {
        let name: String
        let primaryAppKit: CGRect
        let secondaryAppKit: CGRect
        let expectedSecondaryGlobal: CGRect
        var testDescription: String { name }
    }

    static let arrangements: [Arrangement] = [
        Arrangement(
            name: "1440×900 の左に 1920×1080（下端揃え。x が負）",
            primaryAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
            secondaryAppKit: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            expectedSecondaryGlobal: CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        ),
        Arrangement(
            name: "1440×900 の右に 1920×1080（下端揃え）",
            primaryAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
            secondaryAppKit: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            expectedSecondaryGlobal: CGRect(x: 1440, y: -180, width: 1920, height: 1080)
        ),
        Arrangement(
            name: "1440×900 の上に 1920×1080（グローバル y が負）",
            primaryAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
            secondaryAppKit: CGRect(x: -240, y: 900, width: 1920, height: 1080),
            expectedSecondaryGlobal: CGRect(x: -240, y: -1080, width: 1920, height: 1080)
        ),
        Arrangement(
            name: "1440×900 の下に 1920×1080",
            primaryAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
            secondaryAppKit: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            expectedSecondaryGlobal: CGRect(x: 0, y: 900, width: 1920, height: 1080)
        ),
        Arrangement(
            name: "1440×900 の右に 2560×1440（上端揃え）",
            primaryAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
            secondaryAppKit: CGRect(x: 1440, y: -540, width: 2560, height: 1440),
            expectedSecondaryGlobal: CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        ),
        Arrangement(
            name: "2560×1440 の右に 1440×900（下端揃え）",
            primaryAppKit: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            secondaryAppKit: CGRect(x: 2560, y: 0, width: 1440, height: 900),
            expectedSecondaryGlobal: CGRect(x: 2560, y: 540, width: 1440, height: 900)
        ),
        Arrangement(
            name: "2560×1440 の左に 1440×900（上端揃え。x が負）",
            primaryAppKit: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            secondaryAppKit: CGRect(x: -1440, y: 540, width: 1440, height: 900),
            expectedSecondaryGlobal: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        ),
    ]

    @Test("主ディスプレイはグローバル座標で原点 (0, 0) になる", arguments: arrangements)
    func primaryIsOrigin(_ arrangement: Arrangement) {
        let primary = CoordinateConverter.globalRect(
            fromAppKit: arrangement.primaryAppKit,
            primaryHeight: arrangement.primaryAppKit.height
        )

        #expect(primary.rect == CGRect(origin: .zero, size: arrangement.primaryAppKit.size))
    }

    @Test("副ディスプレイの AppKit → グローバル", arguments: arrangements)
    func secondaryToGlobal(_ arrangement: Arrangement) {
        let secondary = CoordinateConverter.globalRect(
            fromAppKit: arrangement.secondaryAppKit,
            primaryHeight: arrangement.primaryAppKit.height
        )

        #expect(secondary.rect == arrangement.expectedSecondaryGlobal)
    }

    @Test("globalRect ↔ appKitRect の往復で元に戻る", arguments: arrangements)
    func roundTrip(_ arrangement: Arrangement) {
        let primaryHeight = arrangement.primaryAppKit.height
        // 画面そのものに加えて、副ディスプレイの中にある要素の矩形も往復させる
        let element = CGRect(
            x: arrangement.secondaryAppKit.minX + 100,
            y: arrangement.secondaryAppKit.minY + 50,
            width: 80,
            height: 24
        )

        for appKit in [arrangement.primaryAppKit, arrangement.secondaryAppKit, element] {
            let global = CoordinateConverter.globalRect(fromAppKit: appKit, primaryHeight: primaryHeight)
            #expect(CoordinateConverter.appKitRect(from: global, primaryHeight: primaryHeight) == appKit)
        }

        let global = GlobalRect(rect: arrangement.expectedSecondaryGlobal)
        let appKit = CoordinateConverter.appKitRect(from: global, primaryHeight: primaryHeight)
        #expect(appKit == arrangement.secondaryAppKit)
        #expect(CoordinateConverter.globalRect(fromAppKit: appKit, primaryHeight: primaryHeight) == global)
    }

    @Test("localPoint はグローバル座標から画面の左上を引いた値", arguments: arrangements)
    func localPoint(_ arrangement: Arrangement) {
        let screen = ScreenGeometry(
            id: ScreenID(rawValue: 1),
            frame: CoordinateConverter.globalRect(
                fromAppKit: arrangement.secondaryAppKit,
                primaryHeight: arrangement.primaryAppKit.height
            )
        )
        let origin = arrangement.expectedSecondaryGlobal.origin

        #expect(CoordinateConverter.localPoint(origin, in: screen) == .zero)
        #expect(
            CoordinateConverter.localPoint(CGPoint(x: origin.x + 120, y: origin.y + 30), in: screen)
                == CGPoint(x: 120, y: 30)
        )
    }

    @Test("主ディスプレイでは localPoint はグローバル座標と同じ")
    func localPointOnPrimary() {
        let primary = ScreenGeometry(
            id: ScreenID(rawValue: 0),
            frame: GlobalRect(rect: CGRect(x: 0, y: 0, width: 1440, height: 900))
        )

        #expect(CoordinateConverter.localPoint(CGPoint(x: 10, y: 20), in: primary) == CGPoint(x: 10, y: 20))
    }

    @Test("AppKit の矩形の上端がグローバル座標の y になる（y の向きの反転）")
    func flipsVerticalAxis() {
        // 主ディスプレイ 1440×900 の左上にある高さ 24 のメニューバー相当の矩形
        let menuBar = CGRect(x: 0, y: 876, width: 1440, height: 24)

        let global = CoordinateConverter.globalRect(fromAppKit: menuBar, primaryHeight: 900)

        #expect(global.rect == CGRect(x: 0, y: 0, width: 1440, height: 24))
    }
}
