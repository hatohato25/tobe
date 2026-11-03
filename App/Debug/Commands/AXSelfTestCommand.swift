#if DEBUG
    import AppKit
    import ApplicationServices
    import TobiCore

    /// `--ax-selftest`: AX のラッパー（`AXClient` / `AXValueDecoder`）の動作確認（T40）。
    ///
    /// Finder の最前面のウィンドウ（`AXWindows` の先頭）について、次をログ（category: debug）に出す。
    /// 1. 一括取得（`AXRole` / `AXSubrole` / `AXPosition` / `AXSize` / `AXEnabled` / `AXChildren` と存在しない属性）の
    ///    属性ごとの型付きの値、またはエラー
    /// 2. 存在しない属性の単独の読み取りが `attributeUnsupported` になること
    /// 3. 型の違う変換（`AXRole` を Bool として読む）が `typeMismatch` になること
    /// 4. アクション名、参照ごとのタイムアウトの設定（0 を拒否すること）
    ///
    /// 期待と違う結果が 1 つでもあれば、まとめて投げる（終了コード 1）。
    /// ウィンドウのタイトルなど画面の内容は読まない。ログに出すのはロール・座標・件数・エラーの種類だけ。
    /// Finder にウィンドウを 1 つ開いた状態で実行する（Finder を前面にする必要はない）。
    struct AXSelfTestCommand: DebugCommand {
        private static let finderBundleID = "com.apple.finder"
        private static let missingAttribute = "AXTobiNonexistentAttribute"

        func run() async throws {
            guard AXIsProcessTrusted() else { throw AXSelfTestError.notTrusted }
            let client = AXClient()
            try client.applySystemWideMessagingTimeout()
            Log.debug.info("システム全体のタイムアウトを設定した: \(AXClient.systemWideMessagingTimeout, privacy: .public)")

            guard
                let finder = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID).first
            else {
                throw AXSelfTestError.finderNotRunning
            }
            let app = AXElementRef.application(pid: finder.processIdentifier)
            let windows = try AXValueDecoder.elements(client.attributeValue(kAXWindowsAttribute, of: app))
            Log.debug.info("Finder のウィンドウ数: \(windows.count, privacy: .public)")
            guard let window = windows.first else { throw AXSelfTestError.noWindow }

            var failures: [String] = []
            failures += try Self.checkMultipleRead(client: client, window: window)
            failures += Self.checkMissingAttribute(client: client, window: window)
            failures += try Self.checkActionsAndTimeout(client: client, window: window)

            guard failures.isEmpty else { throw AXSelfTestError.unexpected(failures) }
            Log.debug.notice("AX のセルフテスト: すべて期待どおり")
        }

        /// 一括取得の各属性を型付きの値にしてログに出す。役割・位置・大きさが取れなければ失敗に数える。
        private static func checkMultipleRead(client: AXClient, window: AXElementRef) throws -> [String] {
            let attributes = [
                kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                kAXEnabledAttribute, kAXChildrenAttribute, missingAttribute,
            ]
            let values = try client.attributeValues(attributes, of: window)
            var failures: [String] = []

            func report<T>(_ attribute: String, required: Bool, _ decode: () throws(AXValueDecodingError) -> T) {
                do {
                    let value = try decode()
                    Log.debug.info("\(attribute, privacy: .public) = \(String(describing: value), privacy: .public)")
                } catch {
                    Log.debug.info("\(attribute, privacy: .public): \(error.description, privacy: .public)")
                    if required { failures.append("\(attribute): \(error.description)") }
                }
            }
            // ロールとサブロールは AX の固定の語彙なので public で出す（タイトルや値は読まない）
            report(kAXRoleAttribute, required: true) { () throws(AXValueDecodingError) in
                try values.string(kAXRoleAttribute)
            }
            report(kAXSubroleAttribute, required: false) { () throws(AXValueDecodingError) in
                try values.string(kAXSubroleAttribute)
            }
            report(kAXPositionAttribute, required: true) { () throws(AXValueDecodingError) in
                try values.point(kAXPositionAttribute)
            }
            report(kAXSizeAttribute, required: true) { () throws(AXValueDecodingError) in
                try values.size(kAXSizeAttribute)
            }
            report(kAXEnabledAttribute, required: false) { () throws(AXValueDecodingError) in
                try values.bool(kAXEnabledAttribute)
            }
            report("\(kAXChildrenAttribute).count", required: true) { () throws(AXValueDecodingError) in
                try values.elements(kAXChildrenAttribute).count
            }

            // 存在しない属性は、一括取得ではその位置のエラー（attributeUnsupported）になる
            do {
                let value = try values.string(missingAttribute)
                failures.append("一括取得の存在しない属性が値を返した: \(value.count) 文字")
            } catch .attributeError(.attributeUnsupported) {
                Log.debug.info("一括取得の存在しない属性: attributeError(attributeUnsupported)（期待どおり）")
            } catch {
                failures.append("一括取得の存在しない属性: \(error.description)")
            }

            // 型の違う変換は typeMismatch になる
            do {
                _ = try values.bool(kAXRoleAttribute)
                failures.append("AXRole を Bool として読めてしまった")
            } catch .typeMismatch(expected: .bool, actualTypeID: _) {
                Log.debug.info("AXRole を Bool として読む: typeMismatch（期待どおり）")
            } catch {
                failures.append("AXRole を Bool として読む: \(error.description)")
            }
            return failures
        }

        /// 存在しない属性の単独の読み取りが `attributeUnsupported` になるかを確かめる。
        private static func checkMissingAttribute(client: AXClient, window: AXElementRef) -> [String] {
            do {
                _ = try client.attributeValue(missingAttribute, of: window)
                return ["存在しない属性の単独の読み取りが成功した"]
            } catch .attributeUnsupported {
                Log.debug.info("存在しない属性の単独の読み取り: attributeUnsupported（期待どおり）")
                return []
            } catch {
                return ["存在しない属性の単独の読み取り: \(error)"]
            }
        }

        /// アクション名を読み、参照ごとのタイムアウトの設定（と 0 の拒否）を確かめる。
        private static func checkActionsAndTimeout(client: AXClient, window: AXElementRef) throws -> [String] {
            var failures: [String] = []
            let actions = try AXValueDecoder.strings(client.actionNames(of: window))
            Log.debug.info("ウィンドウのアクション: \(actions.joined(separator: ", "), privacy: .public)")

            try client.setMessagingTimeout(.milliseconds(200), for: window)
            let role = try AXValueDecoder.string(client.attributeValue(kAXRoleAttribute, of: window))
            Log.debug.info("参照ごとのタイムアウト 200ms を設定して読んだ AXRole = \(role, privacy: .public)")

            do {
                try client.setMessagingTimeout(.zero, for: window)
                failures.append("タイムアウト 0 が受け付けられた")
            } catch {
                Log.debug.info("タイムアウト 0 の設定: \(String(describing: error), privacy: .public)（拒否。期待どおり）")
            }
            return failures
        }
    }

    private enum AXSelfTestError: Error, CustomStringConvertible {
        case notTrusted
        case finderNotRunning
        case noWindow
        case unexpected([String])

        var description: String {
            switch self {
            case .notTrusted:
                "アクセシビリティが許可されていない（システム設定 > プライバシーとセキュリティ > アクセシビリティ）"
            case .finderNotRunning:
                "Finder が起動していない"
            case .noWindow:
                "Finder のウィンドウがない（ウィンドウを 1 つ開いてから実行する）"
            case .unexpected(let failures):
                "期待と違う結果: \(failures.joined(separator: " / "))"
            }
        }
    }
#endif
