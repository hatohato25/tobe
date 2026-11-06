#if DEBUG
    import AppKit
    import CoreGraphics
    import TobeCore

    /// `--dump-screens`: 画面ごとの座標の情報をログ（category: debug）に出す（T43）。
    ///
    /// 画面ごとに次を 1 行で出す。
    /// - `ScreenGeometryProvider` が作った `ScreenGeometry`（id とグローバル座標の frame）
    /// - 元の `NSScreen.frame`（AppKit の座標）と `backingScaleFactor`
    /// - `CGDisplayBounds`（CoreGraphics が返すグローバル座標。変換式と独立した答え合わせ）と、`ScreenGeometry` との一致
    ///
    /// 起動時に 1 回出したあと、画面の構成が変わる（ディスプレイの配置の変更・抜き差し）たびに出し直す。
    /// 終了しないので、Ctrl-C などで止める。
    /// 画面の内容は読まない（出すのは座標・倍率・ディスプレイ ID・画面の名前だけ）。
    struct DumpScreensCommand: DebugCommand {
        /// 一致とみなす差（ポイント）。frame はポイントの整数値になるので、丸め誤差だけを許す。
        private static let tolerance: CGFloat = 0.5

        func run() async throws {
            let provider = ScreenGeometryProvider()
            let changes = provider.screenChanges()
            Self.dump(provider.currentSnapshots(), reason: "起動時")
            for await _ in changes {
                Self.dump(provider.currentSnapshots(), reason: "画面の構成の変更")
            }
        }

        private static func dump(_ snapshots: [ScreenSnapshot], reason: String) {
            Log.debug.notice(
                "--dump-screens [\(reason, privacy: .public)] 画面の数: \(snapshots.count, privacy: .public)"
            )
            var mismatchCount = 0
            for snapshot in snapshots {
                let comparison = compare(snapshot)
                if comparison == .mismatch {
                    mismatchCount += 1
                }
                log(snapshot, comparison: comparison)
            }
            if mismatchCount == 0 {
                Log.debug.notice("--dump-screens: CGDisplayBounds と一致しない画面はない")
            } else {
                Log.debug.error("--dump-screens: CGDisplayBounds と一致しない画面が \(mismatchCount, privacy: .public) 枚ある")
            }
        }

        private enum Comparison {
            case match
            case mismatch
            /// ディスプレイ ID が取れず、`CGDisplayBounds` を読めない。
            case unavailable
        }

        private static func compare(_ snapshot: ScreenSnapshot) -> Comparison {
            guard let displayID = snapshot.displayID else { return .unavailable }
            let global = snapshot.geometry.frame.rect
            let bounds = CGDisplayBounds(displayID)
            let matches =
                abs(global.minX - bounds.minX) < tolerance
                && abs(global.minY - bounds.minY) < tolerance
                && abs(global.width - bounds.width) < tolerance
                && abs(global.height - bounds.height) < tolerance
            return matches ? .match : .mismatch
        }

        private static func log(_ snapshot: ScreenSnapshot, comparison: Comparison) {
            let index = snapshot.geometry.id.rawValue
            let primaryMark = index == 0 ? "(主)" : ""
            let idText = snapshot.displayID.map { String($0) } ?? "不明"
            let boundsText = snapshot.displayID.map { format(CGDisplayBounds($0)) } ?? "取得できない"
            let comparisonText =
                switch comparison {
                case .match: "一致"
                case .mismatch: "不一致"
                case .unavailable: "比較できない"
                }
            Log.debug.notice(
                """
                screen[\(index, privacy: .public)]\(primaryMark, privacy: .public) \
                displayID=\(idText, privacy: .public) name=\(snapshot.screen.localizedName, privacy: .public) \
                scale=\(format(snapshot.screen.backingScaleFactor), privacy: .public) \
                global=\(format(snapshot.geometry.frame.rect), privacy: .public) \
                appKit=\(format(snapshot.screen.frame), privacy: .public) \
                CGDisplayBounds=\(boundsText, privacy: .public) (\(comparisonText, privacy: .public))
                """
            )
        }

        private static func format(_ value: CGFloat) -> String {
            if value == value.rounded() { return String(Int(value)) }
            return String(format: "%.2f", Double(value))
        }

        private static func format(_ rect: CGRect) -> String {
            "(\(format(rect.minX)), \(format(rect.minY)), \(format(rect.width))x\(format(rect.height)))"
        }
    }
#endif
