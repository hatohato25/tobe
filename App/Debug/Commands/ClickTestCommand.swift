#if DEBUG
    import AppKit
    import ApplicationServices
    import TobeCore

    /// `--click-test`: TextEdit の本文の中心をマウスイベントでクリックする（T47。代替クリックの手動確認）。
    ///
    /// 1. TextEdit をアクティブにする（クリックの位置に別のアプリのウィンドウが重なっていないようにするため。
    ///    本体の代替クリックはアクティブ化しない。暫定 Q-18）
    /// 2. AX で最前面のウィンドウから本文（`AXTextArea` を子に持つ `AXScrollArea`。見えている範囲）を探し、
    ///    その位置と大きさを `GlobalRect` にする（`AXTextArea` 自体は文書全体の高さを持つので、中心が画面外になり得る）
    /// 3. `MouseClickPoster` を MainActor の外（`Task.detached`）から呼び、中心をクリックする（T46 の呼び方と同じ）
    ///
    /// ログ（category: debug）に出すのは座標とカーソルの位置だけ。本文の中身は読まない。
    /// TextEdit で書類を 1 つ開いた状態で実行する。
    struct ClickTestCommand: DebugCommand {
        private static let textEditBundleID = "com.apple.TextEdit"
        /// アクティブ化してからウィンドウが前面に来るまでの待ち時間。
        private static let activationDelay: Duration = .milliseconds(500)
        /// 本文を探す深さの上限。TextEdit はウィンドウ → `AXScrollArea` → `AXTextArea` の 2 段。
        private static let searchDepth = 4

        func run() async throws {
            guard AXIsProcessTrusted() else { throw ClickTestError.notTrusted }
            guard
                let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: Self.textEditBundleID)
                    .first
            else {
                throw ClickTestError.textEditNotRunning
            }
            textEdit.activate()
            try await Task.sleep(for: Self.activationDelay)

            let client = AXClient()
            try client.applySystemWideMessagingTimeout()
            let app = AXElementRef.application(pid: textEdit.processIdentifier)
            let windows = try AXValueDecoder.elements(client.attributeValue(kAXWindowsAttribute, of: app))
            guard let window = windows.first else { throw ClickTestError.noWindow }
            guard let body = try Self.findBody(in: window, client: client, depth: Self.searchDepth) else {
                throw ClickTestError.bodyNotFound
            }
            let values = try client.attributeValues([kAXPositionAttribute, kAXSizeAttribute], of: body)
            let frame = GlobalRect(
                rect: CGRect(origin: try values.point(kAXPositionAttribute), size: try values.size(kAXSizeAttribute))
            )
            let rectText = String(describing: frame.rect)
            let centerText = String(describing: frame.center)
            Log.debug.info("本文の枠: \(rectText, privacy: .public)、中心: \(centerText, privacy: .public)")
            Self.logCursor("クリック前")

            let poster = MouseClickPoster()
            // T46 は MainActor の外から呼ぶので、同じ条件で確かめる
            try await Task.detached { try poster.clickCenter(of: frame) }.value

            Self.logCursor("クリック後")
            Log.debug.notice(
                "代替クリックを送った（印: \(TobeEventMarker.value, privacy: .public)）。TextEdit のキャレットが本文の中心へ移ったかを目で確かめる"
            )
        }

        /// `AXTextArea` を子に持つ `AXScrollArea` を、深さ優先で `depth` 段まで探す。
        private static func findBody(
            in element: AXElementRef,
            client: AXClient,
            depth: Int
        ) throws -> AXElementRef? {
            guard depth > 0 else { return nil }
            let children = try childElements(of: element, client: client)
            for child in children {
                let role = try AXValueDecoder.string(client.attributeValue(kAXRoleAttribute, of: child))
                if role == kAXScrollAreaRole {
                    let grandchildren = try childElements(of: child, client: client)
                    for grandchild in grandchildren {
                        let childRole = try AXValueDecoder.string(
                            client.attributeValue(kAXRoleAttribute, of: grandchild))
                        if childRole == kAXTextAreaRole { return child }
                    }
                }
                if let found = try findBody(in: child, client: client, depth: depth - 1) { return found }
            }
            return nil
        }

        /// 子の一覧。子を持たない要素（`attributeUnsupported`）は空として扱う。
        private static func childElements(of element: AXElementRef, client: AXClient) throws -> [AXElementRef] {
            do {
                return try AXValueDecoder.elements(client.attributeValue(kAXChildrenAttribute, of: element))
            } catch let error as AccessibilityReadError where error == .attributeUnsupported {
                return []
            }
        }

        /// 現在のカーソルの位置（グローバル座標）をログに出す。Q-17 でカーソルを戻さないことの確認用。
        private static func logCursor(_ label: String) {
            guard let location = CGEvent(source: nil)?.location else {
                Log.debug.error("カーソルの位置を読めなかった")
                return
            }
            Log.debug.info("\(label, privacy: .public)のカーソル: \(String(describing: location), privacy: .public)")
        }
    }

    private enum ClickTestError: Error, CustomStringConvertible {
        case notTrusted
        case textEditNotRunning
        case noWindow
        case bodyNotFound

        var description: String {
            switch self {
            case .notTrusted:
                "アクセシビリティが許可されていない（システム設定 > プライバシーとセキュリティ > アクセシビリティ）"
            case .textEditNotRunning:
                "TextEdit が起動していない"
            case .noWindow:
                "TextEdit のウィンドウがない（書類を 1 つ開いてから実行する）"
            case .bodyNotFound:
                "TextEdit のウィンドウに本文（AXTextArea を子に持つ AXScrollArea）が見つからない"
            }
        }
    }
#endif
