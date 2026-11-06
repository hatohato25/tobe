import Testing

@testable import TobeCore

@Suite("中身の公開を頼むアプリの判定（W-1）")
struct ContentExposureKindTests {
    struct Case: Sendable {
        let name: String
        let frameworks: [String]
        let helpers: [String]
        let expected: ContentExposureKind?
    }

    @Test(
        "バンドルの中身から種類を決める",
        arguments: [
            Case(
                name: "VS Code",
                frameworks: ["Code Helper (Renderer).app", "Electron Framework.framework", "Squirrel.framework"],
                helpers: [],
                expected: .electron
            ),
            Case(
                name: "Chrome",
                frameworks: ["Google Chrome Framework.framework"],
                helpers: ["Google Chrome Helper (GPU).app", "Google Chrome Helper (Renderer).app"],
                expected: .chromiumBrowser
            ),
            Case(
                name: "Electron のフレームワークを優先する",
                frameworks: ["Electron Framework.framework"],
                helpers: ["Foo Helper (Renderer).app"],
                expected: .electron
            ),
            Case(
                name: "ヘルパーがレンダラーでない",
                frameworks: ["Foo.framework"],
                helpers: ["Foo Helper (GPU).app", "Foo Helper.app"],
                expected: nil
            ),
            Case(name: "フレームワークがない", frameworks: [], helpers: [], expected: nil),
        ]
    )
    func classify(_ testCase: Case) {
        #expect(
            ContentExposureKind.classify(frameworkNames: testCase.frameworks, helperNames: testCase.helpers)
                == testCase.expected,
            "\(testCase.name)"
        )
    }
}
