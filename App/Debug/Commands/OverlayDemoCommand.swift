#if DEBUG
    import AppKit
    import CoreGraphics
    import TobiCore

    /// `--overlay-demo`: 固定のラベル 20 個を、全ディスプレイにそれぞれ表示する（T44。T45 が絞り込みと非表示を足す）。
    ///
    /// - 画面ごとに `OverlayPanel` を 1 枚作り、5 列 × 4 行の格子にラベルを置く。格子の端の列・行は画面の右端・下端に
    ///   anchor を置くので、`HintPlacement.clamp` で画面内に押し戻されて、角と辺にぴったり接して見える（F-3.5）。
    ///   上端の行はメニューバーに重なる（`constrainFrameRect` の override と `.screenSaver` の確認。V-8）。
    /// - 表示の 1 秒後に、Tobi がアクティブになっていないこととパネルがキーになっていないことをログに出す（F-3.7）。
    /// - 画面の構成が変わったら、パネルを作り直して出し直す。
    ///
    /// 終了しないので、Ctrl-C などで止める。ログ（category: debug）にはラベルの文字列を出さない。
    struct OverlayDemoCommand: DebugCommand {
        private static let columns = 5
        private static let rows = 4
        private static let focusCheckDelay: Duration = .seconds(1)

        func run() async throws {
            let provider = ScreenGeometryProvider()
            let changes = provider.screenChanges()
            var panels = try await Self.present(provider.currentSnapshots(), reason: "起動時")
            for await _ in changes {
                for panel in panels {
                    panel.dismiss()
                }
                panels = try await Self.present(provider.currentSnapshots(), reason: "画面の構成の変更")
            }
        }

        /// 画面ごとにパネルを作ってラベルを出す。戻り値のパネルを持ち続けている間だけ表示が残る。
        private static func present(_ snapshots: [ScreenSnapshot], reason: String) async throws -> [OverlayPanel] {
            guard !snapshots.isEmpty else {
                Log.debug.error("--overlay-demo [\(reason, privacy: .public)] 画面がないため表示しない")
                return []
            }
            let alphabet = HintAlphabet.vimiumDefault
            let labels = HintLabelGenerator.labels(count: columns * rows, alphabet: alphabet)
            let panels = snapshots.map { snapshot in
                let panel = OverlayPanel(screenFrame: snapshot.screen.frame)
                panel.hintView.show(placements(for: snapshot.geometry, labels: labels), appearance: .defaults)
                panel.present()
                Log.debug.notice(
                    """
                    --overlay-demo [\(reason, privacy: .public)] \
                    screen[\(snapshot.geometry.id.rawValue, privacy: .public)] ラベル \(labels.count, privacy: .public) 個 \
                    screen.frame=\(format(snapshot.screen.frame), privacy: .public) \
                    panel.frame=\(format(panel.frame), privacy: .public) \
                    frame一致=\(panel.frame == snapshot.screen.frame, privacy: .public)
                    """
                )
                return panel
            }
            try await Task.sleep(for: focusCheckDelay)
            let anyKey = panels.contains { $0.isKeyWindow }
            Log.debug.notice(
                """
                --overlay-demo: NSApp.isActive=\(NSApp.isActive, privacy: .public) \
                パネルがキー=\(anyKey, privacy: .public) \
                前面のアプリ=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "不明", privacy: .public)
                """
            )
            return panels
        }

        /// 画面ローカル座標（左上原点）の格子にラベルを置く。端の列・行は画面の端そのものに anchor を置く。
        private static func placements(for screen: ScreenGeometry, labels: [String]) -> [HintPlacement] {
            let size = screen.frame.rect.size
            return labels.enumerated().map { index, label in
                let column = index % columns
                let row = index / columns
                let anchor = CGPoint(
                    x: size.width * CGFloat(column) / CGFloat(columns - 1),
                    y: size.height * CGFloat(row) / CGFloat(rows - 1)
                )
                return HintPlacement(
                    // 画面をまたいで ID が重ならないようにする（T45 の絞り込みで画面ごとに区別できるように）
                    elementID: ElementID(rawValue: screen.id.rawValue * 1000 + index),
                    label: label,
                    screenID: screen.id,
                    anchor: anchor
                )
            }
        }

        private static func format(_ rect: CGRect) -> String {
            "(\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width))x\(Int(rect.height)))"
        }
    }
#endif
