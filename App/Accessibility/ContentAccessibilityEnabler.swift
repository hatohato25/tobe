import AppKit
import Synchronization
import TobeCore

/// Electron アプリと Chromium 系のブラウザに、画面の中身をアクセシビリティツリーへ公開するよう頼む（W-1）。
///
/// どちらも、頼まれないと中身をツリーに出さないことがある（VS Code でも、Mac の再起動後にウィンドウの枠だけになった）。
/// Electron には `AXManualAccessibility`、ブラウザには `AXEnhancedUserInterface` を設定する。後者はウィンドウ管理ツールの
/// 動きに影響することがあるので、Electron には使わない。
///
/// 中身の公開は非同期で、実機では頼んでから最大 2〜4 秒かかった。間に合うよう、前面に来た時点でも頼む（`HintModeModule`）。
/// 公開はアプリが終わるまで続き、元に戻さない。
final class ContentAccessibilityEnabler: Sendable {
    /// 起動直後のアプリは応答しないので、タップを待たずに頼み直す間隔と回数（合わせて約 30 秒）。
    private static let retryInterval: TimeInterval = 0.25
    private static let retryLimit = 120

    private let client = AXClient()
    /// 確認の終わったプロセス。頼むのはプロセスごとに 1 回だけにする。
    private let checkedPIDs = Mutex<Set<ProcessID>>([])

    /// 対象のアプリで、まだ頼んでいなければ頼む。ブロッキングの IPC があるので GCD のキューから呼ぶ。
    ///
    /// 失敗しても収集は止めない。中身のラベルが出ないだけで、枠のラベルは出せるため。ログには残す。
    func enableIfNeeded(for pid: ProcessID) {
        // 権限がないときは確認済みにしない。許可された後に頼めなくなるため
        guard AXIsProcessTrusted(), checkedPIDs.withLock({ $0.insert(pid).inserted }), let kind = Self.kind(of: pid)
        else {
            return
        }
        request(pid, kind: kind, retriesLeft: Self.retryLimit)
    }

    private func request(_ pid: ProcessID, kind: ContentExposureKind, retriesLeft: Int) {
        do throws(AccessibilityReadError) {
            try client.setAttribute(Self.attribute(for: kind), to: true, of: .application(pid: pid.rawValue))
            Log.collector.notice(
                "中身の公開を頼んだ: pid \(pid.rawValue, privacy: .public)、\(kind.rawValue, privacy: .public)"
            )
        } catch .notImplemented {
            // Chromium は設定を受け取って中身を公開するが、結果にはこのエラーを返す（Chrome と Brave の実機で確認）。
            // 失敗として扱わない
            Log.collector.notice(
                "中身の公開を頼んだ（notImplemented）: pid \(pid.rawValue, privacy: .public)、\(kind.rawValue, privacy: .public)"
            )
        } catch .cannotComplete {
            guard retriesLeft > 0 else {
                // 次の収集か、次に前面に来たときに頼み直す
                checkedPIDs.withLock { _ = $0.remove(pid) }
                Log.collector.notice(
                    "中身の公開を頼んだアプリが応答しなかった: pid \(pid.rawValue, privacy: .public)、\(kind.rawValue, privacy: .public)"
                )
                return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.retryInterval) {
                self.request(pid, kind: kind, retriesLeft: retriesLeft - 1)
            }
        } catch {
            Log.collector.error(
                """
                中身の公開を頼めなかった: pid \(pid.rawValue, privacy: .public)、\(kind.rawValue, privacy: .public)、\
                \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private static func attribute(for kind: ContentExposureKind) -> String {
        switch kind {
        case .electron: "AXManualAccessibility"
        case .chromiumBrowser: "AXEnhancedUserInterface"
        }
    }

    /// アプリのバンドルの中身から種類を決める。読めないフォルダは「ない」として扱う（対象外になり、枠のラベルだけが出る）。
    private static func kind(of pid: ProcessID) -> ContentExposureKind? {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid.rawValue)?.bundleURL else { return nil }
        let files = FileManager.default
        let frameworksPath = bundleURL.appending(path: "Contents/Frameworks").path(percentEncoded: false)
        guard let frameworks = try? files.contentsOfDirectory(atPath: frameworksPath) else { return nil }
        let helpers = frameworks.filter { $0.hasSuffix(".framework") }.flatMap { framework in
            let path = "\(frameworksPath)/\(framework)/Versions/Current/Helpers"
            return (try? files.contentsOfDirectory(atPath: path)) ?? []
        }
        return ContentExposureKind.classify(frameworkNames: frameworks, helperNames: helpers)
    }
}
