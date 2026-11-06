import Testing

@testable import TobeCore

@Suite("スモークテスト")
struct SmokeTests {
    @Test("TobeCore をリンクして参照できる")
    func moduleIsLinked() {
        #expect(TobeCoreModule.name == "TobeCore")
    }
}
