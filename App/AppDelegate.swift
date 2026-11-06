import AppKit
import os

/// アプリの組み立て役。モジュールを依存の順に生成して開始するだけにする（機能の中身は `App/Modules/`）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // subsystem は Debug / Release で同じ値にして、ログの絞り込み条件を共通にする。
    private let logger = Logger(subsystem: "io.github.hatohato25.tobe", category: "App")

    /// 開始に成功したモジュール（開始した順）。終了時はこの逆順で停止する。
    private var startedModules: [any AppModule] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hotkey = HotkeyModule()
        let hintMode = HintModeModule(hotkey: hotkey)
        let settings = SettingsModule(hotkey: hotkey, hintMode: hintMode)
        let modules: [any AppModule] = [hotkey, hintMode, settings]

        for module in modules {
            do {
                try module.start()
                startedModules.append(module)
            } catch {
                // 一部のモジュールだけが動いている状態で続けると、動いているように見えて機能しないため終了する。
                logger.error(
                    """
                    モジュールの開始に失敗したため終了します: \
                    \(String(describing: type(of: module)), privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
                stopStartedModules()
                // NSApp.terminate(_:) は終了コード 0 になり、異常終了と区別できないため exit で終える。
                exit(EXIT_FAILURE)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStartedModules()
    }

    private func stopStartedModules() {
        for module in startedModules.reversed() {
            module.stop()
        }
        startedModules.removeAll()
    }
}
