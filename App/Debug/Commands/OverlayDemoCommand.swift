#if DEBUG
    import AppKit
    import CoreGraphics
    import TobiCore

    /// `--overlay-demo`: 固定のラベル 20 個を全ディスプレイに出し、絞り込みと非表示を繰り返す（T44 / T45）。
    ///
    /// - `OverlayController`（T45）を通して表示する。画面ごとに 5 列 × 4 行の格子にラベルを置く。格子の端の列・行は
    ///   画面の右端・下端に anchor を置くので、`HintPlacement.clamp` で画面内に押し戻されて、角と辺にぴったり接して
    ///   見える（F-3.5）。上端の行はメニューバーに重なる（`constrainFrameRect` の override と `.screenSaver`。V-8）。
    /// - 1 周（約 11 秒）: 全表示（3 秒）→ 1 文字入力した状態に絞り込み（`update`。3 秒）→ Backspace で戻した状態
    ///   （`update` で全ラベル・入力済み 0 文字。薄くした文字が元に戻る。3 秒）→ 非表示（`hide` を 2 回。2 秒）。
    ///   周ごとに画面の一覧を読み直して出し直す。
    /// - 最初の周だけ、存在しない画面の placement を 1 つ混ぜる（`OverlayController` が捨ててエラーログを出すことの確認）。
    /// - 最初の表示の 1 秒後に、Tobi がアクティブになっていないこととパネルがキーになっていないことをログに出す（F-3.7）。
    /// - 画面の構成が変わったら `rebuildPanels(for:)` でパネルを作り直す（表示中なら隠れる）。次の周から新しい構成で出る。
    ///
    /// 終了しないので、Ctrl-C などで止める。ログ（category: debug）にはラベルの文字列を出さない。
    struct OverlayDemoCommand: DebugCommand {
        private static let columns = 5
        private static let rows = 4
        private static let focusCheckDelay: Duration = .seconds(1)
        private static let showDuration: Duration = .seconds(3)
        private static let filteredDuration: Duration = .seconds(3)
        private static let restoredDuration: Duration = .seconds(3)
        private static let hiddenDuration: Duration = .seconds(2)

        func run() async throws {
            let provider = ScreenGeometryProvider()
            let changes = provider.screenChanges()
            let controller = OverlayController(screens: provider.currentSnapshots())
            let watcher = Task { @MainActor in
                for await _ in changes {
                    Log.debug.notice("--overlay-demo: 画面の構成が変わったため、パネルを作り直す")
                    controller.rebuildPanels(for: provider.currentSnapshots())
                }
            }
            defer { watcher.cancel() }

            let labels = HintLabelGenerator.labels(count: Self.columns * Self.rows, alphabet: .vimiumDefault)
            // 2 文字以上のラベルのうち、最初のラベルの 1 文字目を打った状態を見せる（実際の絞り込みと同じく接頭辞で残す）。
            // 20 個は既定の文字セット（14 文字）より多いので、2 文字のラベルが必ずできる
            guard let twoCharacterLabel = labels.first(where: { $0.count >= 2 }) else {
                Log.debug.error("--overlay-demo: 2 文字以上のラベルがないため、入力済みの文字を見せられない")
                return
            }
            let typed = String(twoCharacterLabel.prefix(1))
            var cycle = 0
            while true {
                // ScreenID は添字なので、周ごとに読み直す（画面の構成の変化の後に古い ID を使わない）
                let screens = provider.currentScreens()
                var placements = screens.flatMap { placements(for: $0, labels: labels) }
                if cycle == 0 {
                    placements.append(orphanPlacement(screenCount: screens.count))
                }

                Log.debug.notice(
                    """
                    --overlay-demo [周 \(cycle, privacy: .public)] 全表示: \
                    画面 \(screens.count, privacy: .public) 枚 placement \(placements.count, privacy: .public) 個
                    """
                )
                controller.show(placements, appearance: .defaults)
                if cycle == 0 {
                    try await Task.sleep(for: Self.focusCheckDelay)
                    Self.logFocusState()
                    try await Task.sleep(for: Self.showDuration - Self.focusCheckDelay)
                } else {
                    try await Task.sleep(for: Self.showDuration)
                }

                try await Self.narrowAndRestore(controller, placements: placements, typed: typed, cycle: cycle)

                Log.debug.notice("--overlay-demo [周 \(cycle, privacy: .public)] 非表示（hide を 2 回）")
                controller.hide()
                // 何も表示していないときに呼んでもよいこと（HintOverlayPresenting の約束）の確認
                controller.hide()
                try await Task.sleep(for: Self.hiddenDuration)
                cycle += 1
            }
        }

        /// `typed` を入力した状態に絞り込み（入力済みの文字を薄く描く）、次に Backspace で戻した状態（全表示、
        /// 入力 0 文字）にする。それぞれの状態を一定時間見せる。
        private static func narrowAndRestore(
            _ controller: OverlayController,
            placements: [HintPlacement],
            typed: String,
            cycle: Int
        ) async throws {
            let visible = Set(placements.filter { $0.label.hasPrefix(typed) }.map(\.elementID))
            Log.debug.notice(
                """
                --overlay-demo [周 \(cycle, privacy: .public)] 絞り込み: \
                \(typed.count, privacy: .public) 文字入力して \(visible.count, privacy: .public) 個を残す
                """
            )
            controller.update(visibleIDs: visible, typedCount: typed.count)
            try await Task.sleep(for: filteredDuration)

            Log.debug.notice("--overlay-demo [周 \(cycle, privacy: .public)] Backspace で戻した状態（全表示、入力 0 文字）")
            controller.update(visibleIDs: Set(placements.map(\.elementID)), typedCount: 0)
            try await Task.sleep(for: restoredDuration)
        }

        private static func logFocusState() {
            let anyKey = NSApp.windows.contains { $0 is OverlayPanel && $0.isKeyWindow }
            let panelFrames = NSApp.windows.compactMap { $0 as? OverlayPanel }.map { format($0.frame) }
            let screenFrames = NSScreen.screens.map { format($0.frame) }
            Log.debug.notice(
                """
                --overlay-demo: NSApp.isActive=\(NSApp.isActive, privacy: .public) \
                パネルがキー=\(anyKey, privacy: .public) \
                前面のアプリ=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "不明", privacy: .public) \
                screen.frame=\(screenFrames.joined(separator: " "), privacy: .public) \
                panel.frame=\(panelFrames.joined(separator: " "), privacy: .public)
                """
            )
        }

        /// 画面ローカル座標（左上原点）の格子にラベルを置く。端の列・行は画面の端そのものに anchor を置く。
        private func placements(for screen: ScreenGeometry, labels: [String]) -> [HintPlacement] {
            let size = screen.frame.rect.size
            return labels.enumerated().map { index, label in
                let column = index % Self.columns
                let row = index / Self.columns
                let anchor = CGPoint(
                    x: size.width * CGFloat(column) / CGFloat(Self.columns - 1),
                    y: size.height * CGFloat(row) / CGFloat(Self.rows - 1)
                )
                return HintPlacement(
                    // 画面をまたいで ID が重ならないようにする（絞り込みで画面ごとに区別できるように）
                    elementID: ElementID(rawValue: screen.id.rawValue * 1000 + index),
                    label: label,
                    screenID: screen.id,
                    anchor: anchor
                )
            }
        }

        /// どの画面にも対応しない `ScreenID`（画面の数と同じ添字）の placement。
        private func orphanPlacement(screenCount: Int) -> HintPlacement {
            HintPlacement(
                elementID: ElementID(rawValue: -1),
                label: "orphan",
                screenID: ScreenID(rawValue: screenCount),
                anchor: .zero
            )
        }

        private static func format(_ rect: CGRect) -> String {
            "(\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width))x\(Int(rect.height)))"
        }
    }
#endif
