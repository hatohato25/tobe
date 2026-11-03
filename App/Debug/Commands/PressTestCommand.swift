#if DEBUG
    import AppKit
    import ApplicationServices
    import TobiCore

    /// `--press-test`: `AXActionPerformer`（T46）で 2 つの要素を操作し、使った方法をログに出す。
    ///
    /// 1. Finder の最前面のウィンドウのツールバーにある「戻る」ボタン（`AXButton` / `AXSegment`）。
    ///    `AXPress` で押せるので `axPress` になるはず（V-4）。
    /// 2. TextEdit の最前面のウィンドウの本文（`AXTextArea` を子に持つ `AXScrollArea`）。
    ///    `AXPress` に非対応なので、代替クリック（`MouseClickPoster`）で `mouseClick` になるはず（V-4）。
    ///    クリックの位置に別のアプリが重ならないよう、TextEdit だけは先にアクティブにする
    ///    （本体の操作はアクティブ化しない。暫定 Q-18）。
    ///
    /// 本体と同じく、`perform` は MainActor の外（GCD のキュー）で動く。ログ（category: debug）に出すのは
    /// 方法とロールだけ。「戻る」ボタンを見分けるために説明（`AXDescription`）を読むが、ログには出さない。
    /// Finder と TextEdit でそれぞれウィンドウを 1 つ開き、Finder は「戻る」が効くようにフォルダを移動してから実行する。
    struct PressTestCommand: DebugCommand {
        private static let finderBundleID = "com.apple.finder"
        private static let textEditBundleID = "com.apple.TextEdit"
        /// 「戻る」ボタンの説明。システムの言語が日本語か英語のときだけ見分けられる（開発用なので割り切る）。
        private static let backButtonDescriptions: Set<String> = ["戻る", "Back"]
        /// アクティブ化してからウィンドウが前面に来るまでの待ち時間。
        private static let activationDelay: Duration = .milliseconds(500)
        /// 探す深さの上限。Finder はウィンドウ → ツールバー → グループ → ボタン、TextEdit はウィンドウ → スクロール領域。
        private static let searchDepth = 5
        /// 対応表には 1 件だけ載せるので、ID は固定でよい。
        private static let elementID = ElementID(rawValue: 1)

        func run() async throws {
            guard AXIsProcessTrusted() else { throw PressTestError.notTrusted }
            let client = AXClient()
            // 本体の起動時（T42）と同じ条件にする。press だけが参照ごとに 1.0 秒を設定する
            try client.applySystemWideMessagingTimeout()

            let finderButton = try Self.findFinderBackButton(client: client)
            let finderMethod = try await Self.press(finderButton, role: kAXButtonRole, client: client)
            Log.debug.notice(
                "Finder の「戻る」: \(String(describing: finderMethod), privacy: .public)（期待: axPress）")

            guard
                let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: Self.textEditBundleID)
                    .first
            else {
                throw PressTestError.appNotRunning(Self.textEditBundleID)
            }
            textEdit.activate()
            try await Task.sleep(for: Self.activationDelay)
            let body = try Self.findTextEditBody(client: client)
            let textEditMethod = try await Self.press(body, role: kAXScrollAreaRole, client: client)
            Log.debug.notice(
                "TextEdit の本文: \(String(describing: textEditMethod), privacy: .public)（期待: mouseClick）")
        }

        /// 本体と同じ組み立て（代替クリックに `MouseClickPoster` を注入）で、`reference` を 1 回操作する。
        private static func press(_ reference: AXElementRef, role: String, client: AXClient) async throws
            -> ActionMethod
        {
            let values = try client.attributeValues([kAXPositionAttribute, kAXSizeAttribute], of: reference)
            let frame = GlobalRect(
                rect: CGRect(origin: try values.point(kAXPositionAttribute), size: try values.size(kAXSizeAttribute))
            )
            let element = CollectedElement(
                id: elementID,
                // performer はウィンドウの ID を使わないので、仮の値でよい
                windowID: WindowID(rawValue: 0),
                frame: frame,
                role: role
            )
            let poster = MouseClickPoster()
            let performer = AXActionPerformer(
                client: client,
                lookUpElement: { [elementID] id in id == elementID ? reference : nil },
                fallbackClick: { frame throws(ActionError) in try poster.clickCenter(of: frame) }
            )
            return try await performer.perform(.leftClick, on: element)
        }

        // MARK: - 要素を探す

        private static func findFinderBackButton(client: AXClient) throws -> AXElementRef {
            let window = try frontWindow(bundleID: finderBundleID, client: client)
            let button = try findElement(in: window, client: client, depth: searchDepth) { element in
                let values = try client.attributeValues([kAXRoleAttribute, kAXSubroleAttribute], of: element)
                guard
                    (try? values.string(kAXRoleAttribute)) == kAXButtonRole,
                    (try? values.string(kAXSubroleAttribute)) == "AXSegment"
                else {
                    return false
                }
                // 説明のない要素（attributeUnsupported）は「戻る」ではない
                let description = try? AXValueDecoder.string(
                    client.attributeValue(kAXDescriptionAttribute, of: element))
                return description.map(backButtonDescriptions.contains) ?? false
            }
            guard let button else { throw PressTestError.elementNotFound("Finder の「戻る」ボタン") }
            return button
        }

        private static func findTextEditBody(client: AXClient) throws -> AXElementRef {
            let window = try frontWindow(bundleID: textEditBundleID, client: client)
            let body = try findElement(in: window, client: client, depth: searchDepth) { element in
                let role = try AXValueDecoder.string(client.attributeValue(kAXRoleAttribute, of: element))
                guard role == kAXScrollAreaRole else { return false }
                return try childElements(of: element, client: client).contains { child in
                    (try? AXValueDecoder.string(client.attributeValue(kAXRoleAttribute, of: child))) == kAXTextAreaRole
                }
            }
            guard let body else { throw PressTestError.elementNotFound("TextEdit の本文") }
            return body
        }

        private static func frontWindow(bundleID: String, client: AXClient) throws -> AXElementRef {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                throw PressTestError.appNotRunning(bundleID)
            }
            let root = AXElementRef.application(pid: app.processIdentifier)
            let windows = try AXValueDecoder.elements(client.attributeValue(kAXWindowsAttribute, of: root))
            guard let window = windows.first else { throw PressTestError.noWindow(bundleID) }
            return window
        }

        /// `matches` を満たす要素を、深さ優先で `depth` 段まで探す。
        private static func findElement(
            in element: AXElementRef,
            client: AXClient,
            depth: Int,
            matches: (AXElementRef) throws -> Bool
        ) throws -> AXElementRef? {
            guard depth > 0 else { return nil }
            for child in try childElements(of: element, client: client) {
                if try matches(child) { return child }
                if let found = try findElement(in: child, client: client, depth: depth - 1, matches: matches) {
                    return found
                }
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
    }

    private enum PressTestError: Error, CustomStringConvertible {
        case notTrusted
        case appNotRunning(String)
        case noWindow(String)
        case elementNotFound(String)

        var description: String {
            switch self {
            case .notTrusted:
                "アクセシビリティが許可されていない（システム設定 > プライバシーとセキュリティ > アクセシビリティ）"
            case .appNotRunning(let bundleID):
                "\(bundleID) が起動していない"
            case .noWindow(let bundleID):
                "\(bundleID) のウィンドウがない（ウィンドウを 1 つ開いてから実行する）"
            case .elementNotFound(let target):
                "\(target) が見つからない"
            }
        }
    }
#endif
