import CoreGraphics
import Testing

@testable import TobiCore

@Suite("TraversalPolicy（design.md 8.2、F-2.8）")
struct TraversalPolicyTests {
    private let policy = TraversalPolicy()
    private let normalFrame = GlobalRect(rect: CGRect(x: 10, y: 20, width: 80, height: 24))

    @Test("許可ロールはアクションを確認せずに対象にする", arguments: TraversalPolicy.allowedRoles.sorted())
    func allowedRole(role: String) {
        #expect(policy.evaluate(role: role, isEnabled: true, frame: normalFrame) == .clickable)
    }

    @Test("曖昧ロールはアクション名の確認が要る", arguments: ["AXGroup", "AXImage", "AXCell", "AXUnknown"])
    func ambiguousRole(role: String) {
        #expect(policy.evaluate(role: role, isEnabled: true, frame: normalFrame) == .requiresPressAction)
    }

    @Test(
        "対象外のロールは対象にしない",
        arguments: [
            "AXStaticText", "AXScrollBar", "AXValueIndicator", "AXSplitter", "AXLayoutArea", "AXWindow",
            "AXScrollArea", "AXTable", "AXOutline", "AXList", "AXMenuBar", "AXMenu", "AXToolbar", "",
            // ロールの比較は大文字小文字を区別する（AX のロールは定数文字列）
            "axbutton",
        ]
    )
    func excludedRole(role: String) {
        #expect(policy.evaluate(role: role, isEnabled: true, frame: normalFrame) == .notClickable)
    }

    @Test("許可ロールと曖昧ロールは重ならない")
    func roleSetsAreDisjoint() {
        #expect(TraversalPolicy.allowedRoles.isDisjoint(with: TraversalPolicy.ambiguousRoles))
    }

    @Test("仕様の許可ロールがすべて含まれる")
    func allowedRolesMatchDesign() {
        let expected: Set<String> = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXTextField",
            "AXTextArea", "AXComboBox", "AXDisclosureTriangle", "AXMenuItem", "AXMenuBarItem", "AXRow",
            "AXIncrementor", "AXColorWell",
        ]
        #expect(TraversalPolicy.allowedRoles == expected)
    }

    @Test("曖昧ロールは AXPress があるときだけ対象にする")
    func pressAction() {
        #expect(policy.hasPressAction(["AXShowMenu", "AXPress"]))
        #expect(policy.hasPressAction(["AXPress"]))
        #expect(!policy.hasPressAction([]))
        #expect(!policy.hasPressAction(["AXShowMenu", "AXScrollToVisible"]))
        #expect(!policy.hasPressAction(["axpress"]))
    }

    @Test("無効（AXEnabled == false）は対象外。AXEnabled がない要素は有効として扱う（暫定 Q-13）")
    func enabled() {
        #expect(policy.evaluate(role: "AXButton", isEnabled: false, frame: normalFrame) == .notClickable)
        #expect(policy.evaluate(role: "AXGroup", isEnabled: false, frame: normalFrame) == .notClickable)
        #expect(policy.evaluate(role: "AXButton", isEnabled: nil, frame: normalFrame) == .clickable)
        #expect(policy.evaluate(role: "AXGroup", isEnabled: nil, frame: normalFrame) == .requiresPressAction)
    }

    @Test("ロールまたは frame が取れない要素は対象外")
    func missingAttributes() {
        #expect(policy.evaluate(role: nil, isEnabled: true, frame: normalFrame) == .notClickable)
        #expect(policy.evaluate(role: "AXButton", isEnabled: true, frame: nil) == .notClickable)
    }

    @Test(
        "幅または高さが 0 の要素は対象外",
        arguments: [
            CGRect(x: 10, y: 10, width: 0, height: 20),
            CGRect(x: 10, y: 10, width: 20, height: 0),
            CGRect(x: 10, y: 10, width: 0, height: 0),
        ]
    )
    func zeroArea(rect: CGRect) {
        let frame = GlobalRect(rect: rect)
        #expect(policy.evaluate(role: "AXButton", isEnabled: true, frame: frame) == .notClickable)
        #expect(policy.evaluate(role: "AXGroup", isEnabled: true, frame: frame) == .notClickable)
    }

    @Test("幅・高さが 1 の要素と負の座標の要素は対象にする")
    func smallestAndNegative() {
        let tiny = GlobalRect(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let negative = GlobalRect(rect: CGRect(x: -1920, y: -1080, width: 40, height: 20))
        #expect(policy.evaluate(role: "AXButton", isEnabled: true, frame: tiny) == .clickable)
        #expect(policy.evaluate(role: "AXButton", isEnabled: true, frame: negative) == .clickable)
    }
}
