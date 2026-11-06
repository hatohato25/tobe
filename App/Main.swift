import AppKit
import os

/// アプリのエントリポイント。
///
/// SwiftUI の `App` は使わず、`NSApplication` と `AppDelegate` を明示的に起動する（design.md 12.4、D-24）。
/// トップレベルコードはファイル名が `main.swift` のときだけ使えるため、`@main` の型から起動する。
/// Debug ビルドでは、登録済みの Debug 引数（`DebugCommandRegistry`）があるときだけ、
/// `AppDelegate` の代わりに `DebugCommandHost` でそのコマンドを実行する。
@main
enum TobeMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = makeDelegate()
        application.delegate = delegate
        // NSApplication.delegate は weak 参照。Swift は最後に使った時点で解放してよいので、
        // run()（アプリの終了まで戻らない）の間は明示的に delegate を保持する。
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    @MainActor
    private static func makeDelegate() -> any NSApplicationDelegate {
        #if DEBUG
            let launch: DebugLaunch
            do {
                launch = try DebugCommandRegistry.resolve(arguments: Array(CommandLine.arguments.dropFirst()))
            } catch {
                // 打ち間違いなどを黙って無視して通常起動すると、意図した確認ができていないことに気付けないため終了する。
                Logger(subsystem: "io.github.hatohato25.tobe", category: "debug").error(
                    "起動引数が不正なため終了します: \(error.description, privacy: .public)"
                )
                exit(EXIT_FAILURE)
            }
            switch launch {
            case .normal:
                return AppDelegate()
            case .command(let argument, let type):
                return DebugCommandHost(argument: argument, commandType: type)
            }
        #else
            // Release ビルドには Debug 引数の解釈を含めない（起動引数は読まない）。
            return AppDelegate()
        #endif
    }
}
