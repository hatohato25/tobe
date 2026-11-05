import AppKit
import Synchronization
import TobiCore

/// Electron アプリに、画面の中身をアクセシビリティツリーへ公開するよう頼む（`AXManualAccessibility`。W-1 の前倒し）。
///
/// Electron は、頼まれないと中身をツリーに出さないことがある（VS Code でも、Mac の再起動後にウィンドウの枠だけになった）。
/// 対象は Electron アプリだけ。`AXEnhancedUserInterface` は使わない。ウィンドウ管理ツールの動きに影響するため。
///
/// 中身の公開は非同期で、実機では頼んでから最大 2〜4 秒かかった。間に合うよう、前面に来た時点でも頼む（`HintModeModule`）。
/// 公開はアプリが終わるまで続き、元に戻さない。
final class ElectronAccessibilityEnabler: Sendable {
    private static let attribute = "AXManualAccessibility"
    private static let frameworkPath = "Contents/Frameworks/Electron Framework.framework"
    /// 起動直後のアプリは応答しないので、タップを待たずに頼み直す間隔と回数（合わせて約 30 秒）。
    private static let retryInterval: TimeInterval = 0.25
    private static let retryLimit = 120

    private let client = AXClient()
    /// 確認の終わったプロセス。頼むのはプロセスごとに 1 回だけにする。
    private let checkedPIDs = Mutex<Set<ProcessID>>([])

    /// Electron アプリで、まだ頼んでいなければ頼む。ブロッキングの IPC があるので GCD のキューから呼ぶ。
    ///
    /// 失敗しても収集は止めない。中身のラベルが出ないだけで、枠のラベルは出せるため。ログには残す。
    func enableIfNeeded(for pid: ProcessID) {
        // 権限がないときは確認済みにしない。許可された後に頼めなくなるため
        guard AXIsProcessTrusted(), checkedPIDs.withLock({ $0.insert(pid).inserted }), Self.isElectronApp(pid) else {
            return
        }
        request(pid, retriesLeft: Self.retryLimit)
    }

    private func request(_ pid: ProcessID, retriesLeft: Int) {
        do throws(AccessibilityReadError) {
            try client.setAttribute(Self.attribute, to: true, of: .application(pid: pid.rawValue))
            Log.collector.notice("Electron アプリに中身の公開を頼んだ: pid \(pid.rawValue, privacy: .public)")
        } catch .cannotComplete {
            guard retriesLeft > 0 else {
                // 次の収集か、次に前面に来たときに頼み直す
                checkedPIDs.withLock { _ = $0.remove(pid) }
                Log.collector.notice("Electron アプリが応答しなかった: pid \(pid.rawValue, privacy: .public)")
                return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.retryInterval) {
                self.request(pid, retriesLeft: retriesLeft - 1)
            }
        } catch {
            Log.collector.error(
                """
                Electron アプリに中身の公開を頼めなかった: pid \(pid.rawValue, privacy: .public)、\
                \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private static func isElectronApp(_ pid: ProcessID) -> Bool {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid.rawValue)?.bundleURL else { return false }
        return FileManager.default.fileExists(
            atPath: bundleURL.appending(path: frameworkPath).path(percentEncoded: false))
    }
}
