/// 画面の中身をアクセシビリティツリーへ公開するよう頼む必要があるアプリの種類（W-1）。
///
/// アプリのバンドルの中身の名前だけで判定する。読み取りは App 側の `ContentAccessibilityEnabler` が行う。
public enum ContentExposureKind: String, Equatable, Sendable {
    /// Electron アプリ（VS Code、Orca など）。
    case electron
    /// Chromium 系のブラウザ（Chrome、Edge、Brave など）。
    case chromiumBrowser

    private static let electronFramework = "Electron Framework.framework"
    private static let rendererHelperSuffix = " Helper (Renderer).app"

    /// バンドルの中身の名前から種類を決める。どちらでもなければ `nil`。
    ///
    /// - Parameters:
    ///   - frameworkNames: `Contents/Frameworks` の中の名前。
    ///   - helperNames: 各フレームワークの `Versions/Current/Helpers` の中の名前。Electron のヘルパーはここに置かれない。
    public static func classify(frameworkNames: [String], helperNames: [String]) -> ContentExposureKind? {
        if frameworkNames.contains(electronFramework) {
            return .electron
        }
        if helperNames.contains(where: { $0.hasSuffix(rendererHelperSuffix) }) {
            return .chromiumBrowser
        }
        return nil
    }
}
