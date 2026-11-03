import Foundation
import Testing

@testable import TobiCore

@Suite("操作の失敗と代替クリック（design.md 10 章、Q-19）")
struct ActionErrorTests {
    @Test("AXPress の actionUnsupported は actionUnsupported になり、代替クリックに切り替えてよい")
    func actionUnsupportedAllowsFallback() {
        let error = ActionError(pressFailure: .actionUnsupported)

        #expect(error == .actionUnsupported)
        #expect(error.allowsFallbackClick)
    }

    @Test(
        "actionUnsupported 以外の AX のエラーは accessibility になり、代替クリックしない",
        arguments: [
            AccessibilityReadError.invalidElement,
            .cannotComplete,
            .apiDisabled,
            .attributeUnsupported,
            .notImplemented,
            .other(code: -25_200),
        ]
    )
    func otherAccessibilityErrorsDoNotFallback(failure: AccessibilityReadError) {
        let error = ActionError(pressFailure: failure)

        #expect(error == .accessibility(failure))
        #expect(!error.allowsFallbackClick)
    }

    @Test(
        "AX 以外の失敗では代替クリックしない",
        arguments: [ActionError.elementNotFound(ElementID(rawValue: 1)), .eventCreationFailed]
    )
    func nonAccessibilityErrorsDoNotFallback(error: ActionError) {
        #expect(!error.allowsFallbackClick)
    }
}
