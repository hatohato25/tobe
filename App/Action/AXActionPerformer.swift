import Dispatch
import TobiCore

/// `ActionPerforming` の実装（design.md 10 章、F-5.1、F-5.2、D-19）。確定した要素を `AXPress` し、
/// 押せない要素（`actionUnsupported`）だけ代替クリックで操作する。
///
/// 順序:
/// 1. `lookUpElement` で `ElementID` から AX の参照を引く。なければ `ActionError.elementNotFound`
/// 2. `AXClient.press(_:)`（その参照に 1.0 秒のタイムアウトを設定してから `AXPress`。D-29）
/// 3. 失敗を `ActionError(pressFailure:)` で変換し、`allowsFallbackClick`（= `actionUnsupported`）のときだけ
///    `fallbackClick` で要素の中心をクリックする。それ以外の失敗は代替せずに投げる（`cannotComplete` は
///    相手のアプリで操作が実行済みのことがあり、代替すると二重に操作するおそれがある。Q-19）
/// 4. `fallbackClick` が `nil`（未注入）なら `.actionUnsupported` を投げる（T28 の取り決め）
///
/// - `AXActionNames` を先に読んで `AXPress` を省く最適化はしない（`actionUnsupported` は 0.1〜0.3ms で返り、
///   アクション名の読み取りも IPC 1 回なので節約にならない。design.md 10 章、V-4）。
/// - 対象アプリのアクティブ化やウィンドウを前面に出す処理はしない（暫定 Q-18）。
///
/// スレッド: `AXPress` はモーダルダイアログを開くと相手のアプリが応答するまでブロックするため、
/// MainActor でも Swift Concurrency の協調スレッドプールでもなく、GCD のグローバルキューで実行する（design.md 13 章）。
///
/// ログ（`Log.action`）に出すのは操作の方法（`axPress` / `mouseClick`）、ロール、エラーの種類だけ。
/// 要素のタイトルや値は読まない（F-5.1、F-5.2、design.md 14 章）。
struct AXActionPerformer: ActionPerforming {
    /// `ElementID` から AX の参照を引く口。T42 の `ElementHandleRegistry`（セッションごとの対応表）を結ぶ。
    /// 対応がない（古い要素）ときは `nil` を返す。GCD のキューから呼ぶので、ロックなどで守った実装にする。
    typealias ElementLookup = @Sendable (ElementID) -> AXElementRef?
    /// 要素の枠の中心をクリックする口。T48 が `MouseClickPoster().clickCenter(of:)` を渡す。
    /// GCD のキューから同期で呼ぶ。
    typealias FallbackClick = @Sendable (GlobalRect) throws(ActionError) -> Void

    private let client: AXClient
    private let lookUpElement: ElementLookup
    private let fallbackClick: FallbackClick?

    /// - Parameters:
    ///   - client: `AXPress` に使う AX のラッパー。
    ///   - lookUpElement: `ElementID` から参照を引く。
    ///   - fallbackClick: `actionUnsupported` のときの代替クリック。`nil` のときは代替せず `.actionUnsupported` を投げる。
    ///     既定値を置かないのは、渡し忘れで代替クリックが黙って無効になるのを防ぐため。
    init(client: AXClient, lookUpElement: @escaping ElementLookup, fallbackClick: FallbackClick?) {
        self.client = client
        self.lookUpElement = lookUpElement
        self.fallbackClick = fallbackClick
    }

    func perform(_ action: HintAction, on element: CollectedElement) async throws(ActionError) -> ActionMethod {
        // HintAction に case が増えたら（F-8〜F-10）ここでコンパイルエラーにして、操作の追加を漏らさない
        switch action {
        case .leftClick:
            break
        }
        let result: Result<ActionMethod, ActionError> = await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Result { () throws(ActionError) in try self.leftClick(element) })
            }
        }
        let role = element.role
        switch result {
        case .success(let method):
            Log.action.info(
                "操作した: \(String(describing: method), privacy: .public)、ロール: \(role, privacy: .public)")
        case .failure(let error):
            Log.action.error(
                "操作に失敗した: \(String(describing: error), privacy: .public)、ロール: \(role, privacy: .public)")
        }
        return try result.get()
    }

    /// AX の IPC とイベントの送信を行うキュー。ヒントの確定に続く操作なので、応答を最優先にする（design.md 13 章）。
    private static let queue = DispatchQueue.global(qos: .userInteractive)

    /// GCD のキューの上で、同期に `AXPress` → 必要なら代替クリックを行う。
    private func leftClick(_ element: CollectedElement) throws(ActionError) -> ActionMethod {
        guard let reference = lookUpElement(element.id) else {
            throw .elementNotFound(element.id)
        }
        do throws(AccessibilityReadError) {
            try client.press(reference)
            return .axPress
        } catch {
            let failure = ActionError(pressFailure: error)
            guard failure.allowsFallbackClick else { throw failure }
            guard let fallbackClick else {
                // 未注入のときは、代替できなかったことを呼び出し側に伝える（T28）
                throw .actionUnsupported
            }
            Log.action.debug(
                "AXPress に非対応のため代替クリックにする。ロール: \(element.role, privacy: .public)")
            try fallbackClick(element.frame)
            return .mouseClick
        }
    }
}
