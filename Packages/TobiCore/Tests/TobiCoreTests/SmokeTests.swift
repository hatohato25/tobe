import Testing

@testable import TobiCore

@Suite("スモークテスト")
struct SmokeTests {
    @Test("TobiCore をリンクして参照できる")
    func moduleIsLinked() {
        #expect(TobiCoreModule.name == "TobiCore")
    }
}
