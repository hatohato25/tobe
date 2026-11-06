#if DEBUG
    import AppKit
    import TobeCore
    import os

    /// `--dump-windows`: `WindowEnumerator` の結果（走査の対象・遮蔽の判定用の一覧・スキップした項目）を、前面から順にログに出す。
    ///
    /// ログは category `collector` に出る。ウィンドウ名は出さず、ID・所有者（PID とアプリ名）・レイヤー・zIndex・frame だけを出す。
    /// 列挙に失敗したら（`windowListUnavailable`）そのまま投げ、`DebugCommandHost` が終了コード 1 で終える。
    struct DumpWindowsCommand: DebugCommand {
        func run() async throws {
            let snapshot = try WindowEnumerator().enumerate()
            let logger = Log.collector

            logger.notice("--dump-windows: 走査の対象 \(snapshot.traversalTargets.count) 件（前面から）")
            for window in snapshot.traversalTargets {
                logger.notice("  target \(Self.describe(window), privacy: .public)")
            }

            logger.notice("--dump-windows: 遮蔽の判定用 \(snapshot.occlusionWindows.count) 件（全レイヤー、前面から）")
            for window in snapshot.occlusionWindows {
                logger.notice("  occluder \(Self.describe(window), privacy: .public)")
            }

            logger.notice("--dump-windows: スキップ \(snapshot.diagnostics.count) 件")
            for diagnostic in snapshot.diagnostics {
                logger.notice("  skipped \(String(describing: diagnostic), privacy: .public)")
            }
        }

        private static func describe(_ window: WindowInfo) -> String {
            let pid = window.ownerPID.rawValue
            // 手動確認で Finder / TextEdit を見分けるためのアプリ名。取れないアプリ（終了直後など）は PID だけを出す。
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName.map { " \($0)" } ?? ""
            let frame = window.frame.rect
            return "z=\(window.zIndex) id=\(window.id.rawValue) pid=\(pid)\(appName) layer=\(window.layer) "
                + "frame=(\(frame.origin.x), \(frame.origin.y), \(frame.width), \(frame.height))"
        }
    }
#endif
