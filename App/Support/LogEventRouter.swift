import TobeCore

/// `HintModeCoordinator` が出す `HintModeLogEvent` を、`Log` のカテゴリとレベルに振り分ける（design.md 14 章、T48）。
///
/// TobeCore はログの出し先を知らないので、Coordinator はこの値を `log` クロージャに渡すだけにしている。
/// 出来事に含まれるのはセッションの番号・件数・時間・エラーの種類・ロールだけで、要素のタイトルや値はない。
/// そのため、補間する値はすべて `privacy: .public` にしてよい（`windowListEntrySkipped` の理由も
/// `WindowListParser` が固定の語彙と添字だけで作っている）。
///
/// 同じ内容が別の場所からも出ているものは、重複しないようにレベルを下げている。
/// - `actionPerformed` / `actionFailed`: `AXActionPerformer` が同じ内容（方法・ロール・エラー）を
///   `Log.action` の info / error に出している。ここでは debug にして、通常のログに 2 回出ないようにする。
/// - `collectionFinished`: `AXElementCollector` がアプリごとの内訳を `Log.collector` の info に出している。
///   こちらは「どのセッションの結果か」と、Coordinator から見た所要時間（MainActor に戻るまでを含む）を
///   info で 1 行だけ出す。
/// - `collectionDiagnostic`: 内訳の行（info）にも終了理由やエラーの件数が出るが、F-2.13 の診断として
///   Console で既定の表示のまま見つけられるよう、こちらは notice にする。
enum LogEventRouter {
    static func route(_ event: HintModeLogEvent) {
        switch event {
        case .collectionFinished(let session, let elementCount, let elapsed):
            Log.collector.info(
                """
                セッション \(session.rawValue, privacy: .public): 収集が終わった（要素 \(elementCount, privacy: .public) 件、\
                \(String(describing: elapsed), privacy: .public)）
                """)
        case .collectionDiagnostic(let session, let diagnostic):
            Log.collector.notice(
                """
                セッション \(session.rawValue, privacy: .public): 収集の診断: \
                \(describe(diagnostic), privacy: .public)
                """)
        case .collectionFailed(let session, let error, let elapsed):
            routeCollectionFailure(session: session, error: error, elapsed: elapsed)
        case .hintsTruncated(let count):
            Log.collector.notice("要素が上限を超えたため \(count, privacy: .public) 件を切り捨てた")
        case .hintsShown(let count):
            Log.overlay.info("ラベルを \(count, privacy: .public) 件表示した")
        case .noScreensForHints(let hintCount):
            Log.overlay.error("表示できる画面がないため、ラベル \(hintCount, privacy: .public) 件を置けなかった")
        case .actionPerformed(let method, let role):
            // info は AXActionPerformer が出している（型の説明を参照）
            Log.action.debug(
                """
                Coordinator: 操作が終わった（\(String(describing: method), privacy: .public)、\
                ロール: \(role, privacy: .public)）
                """)
        case .actionFailed(let error, let role):
            // error は AXActionPerformer が出している（型の説明を参照）。この後 Coordinator が失敗の音を鳴らす
            Log.action.debug(
                """
                Coordinator: 操作が失敗した（\(String(describing: error), privacy: .public)、\
                ロール: \(role, privacy: .public)）
                """)
        }
    }

    private static func routeCollectionFailure(session: SessionID, error: CollectionError, elapsed: Duration) {
        switch error {
        case .cancelled:
            // Esc・マウスの押下・画面の構成の変化で止めた収集。異常ではない（F-6.2）
            Log.collector.info(
                """
                セッション \(session.rawValue, privacy: .public): 収集を取り消した\
                （\(String(describing: elapsed), privacy: .public)）
                """)
        case .accessibilityNotTrusted, .windowListUnavailable:
            Log.collector.error(
                """
                セッション \(session.rawValue, privacy: .public): 収集に失敗した: \
                \(String(describing: error), privacy: .public)（\(String(describing: elapsed), privacy: .public)）
                """)
        }
    }

    /// 診断を 1 行の文字列にする。PID・件数・エラーの種類だけを含む。
    private static func describe(_ diagnostic: CollectionDiagnostic) -> String {
        switch diagnostic {
        case .deadlineExceeded(let pid, let collected):
            "pid \(pid.rawValue): 期限までに走査が終わらなかった（\(collected) 件まで収集）"
        case .nodeBudgetExhausted(let pid):
            "pid \(pid.rawValue): 走査するノード数の上限に達した"
        case .unresponsive(let pid):
            "pid \(pid.rawValue): 応答しないため走査を打ち切った"
        case .readFailed(let pid, let error, let count):
            "pid \(pid.rawValue): 読み取りの失敗 \(error) が \(count) 件"
        case .windowListEntrySkipped(let reason):
            "ウィンドウの一覧の項目をスキップした: \(reason)"
        }
    }
}
