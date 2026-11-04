import Foundation

/// ヒントモードの状態遷移（design.md 5.2）。
///
/// 副作用を持たない純粋なリデューサ。イベントを受けて状態を進め、順序付きのエフェクトを返す。
/// エフェクトをポートの呼び出しに変えるのは `HintModeCoordinator` の役割（D-2）。
public struct HintModeMachine: Sendable {
    public private(set) var state: HintModeState = .idle
    /// 最後に払い出した `SessionID` の値。0 はまだ払い出していないことを表す（最初の ID は 1）。
    private var lastSessionRawValue: UInt64 = 0

    public init() {}

    /// イベントを処理し、状態を進めて、実行すべきエフェクトを順序どおりに返す。
    public mutating func send(_ event: HintModeEvent) -> [HintModeEffect] {
        switch state {
        case .idle:
            return handleIdle(event)
        case .collecting(let context):
            return handleCollecting(event, context: context)
        case .selecting(let context):
            return handleSelecting(event, context: context)
        }
    }

    // MARK: - idle

    private mutating func handleIdle(_ event: HintModeEvent) -> [HintModeEffect] {
        guard case .triggerTapped(let alphabet) = event else {
            // 待機中に届いた収集結果・キー・ポインタ・画面構成の変化はすべて無視する
            return []
        }
        lastSessionRawValue += 1
        let sessionID = SessionID(rawValue: lastSessionRawValue)
        state = .collecting(CollectingContext(sessionID: sessionID, alphabet: alphabet))
        // キー破棄はタップスレッドがすでに ON にしているが、状態とフラグを同じ場所で表すために出す（2 回 ON にしてよい）
        return [.setKeySuppression(true), .startCollection(sessionID)]
    }

    // MARK: - collecting

    private mutating func handleCollecting(
        _ event: HintModeEvent,
        context: CollectingContext
    ) -> [HintModeEffect] {
        switch event {
        case .collectionSucceeded(let sessionID, let result):
            guard sessionID == context.sessionID else { return [] }  // 古い結果は捨てる（F-6.2）
            return finishCollection(with: result, context: context)
        case .collectionFailed(let sessionID, _):
            guard sessionID == context.sessionID else { return [] }  // 古い結果は捨てる（F-6.2）
            // 失敗の理由のログは Coordinator が出す（イベントの値を持っているため）
            state = .idle
            return [.setKeySuppression(false), .playFailure]
        case .key(.escape), .pointerDown, .screensChanged:
            state = .idle
            return [.cancelCollection(context.sessionID), .setKeySuppression(false)]
        case .key:
            // 収集中の Esc 以外のキーは破棄するだけ（暫定 Q-4）
            return []
        case .triggerTapped:
            // 収集中の再タップは無視する（暫定 Q-3）
            return []
        }
    }

    private mutating func finishCollection(
        with result: CollectionResult,
        context: CollectingContext
    ) -> [HintModeEffect] {
        let pipeline = HintPipeline.makeHints(from: result, alphabet: context.alphabet)
        guard !pipeline.hints.isEmpty else {
            // 要素が 0 件ならヒントモードに入らず、失敗の音で知らせる（暫定 Q-11）
            state = .idle
            return [.setKeySuppression(false), .playFailure]
        }
        state = .selecting(SelectionContext(sessionID: context.sessionID, hints: pipeline.hints, typed: ""))
        var effects: [HintModeEffect] = []
        if pipeline.truncatedCount > 0 {
            effects.append(.reportTruncatedHints(count: pipeline.truncatedCount))
        }
        effects.append(.showHints(pipeline.hints))
        return effects
    }

    // MARK: - selecting

    private mutating func handleSelecting(
        _ event: HintModeEvent,
        context: SelectionContext
    ) -> [HintModeEffect] {
        switch event {
        case .key(.character(let character)):
            return selectCharacter(character, context: context)
        case .key(.backspace):
            return deleteLastCharacter(context: context)
        case .key(.escape), .pointerDown, .screensChanged:
            state = .idle
            return [.hideHints, .setKeySuppression(false)]
        case .key(.ignored):
            return []
        case .triggerTapped:
            // ラベル入力中の再タップは無視する（暫定 Q-3）
            return []
        case .collectionSucceeded, .collectionFailed:
            // 収集はラベルの表示前に終わっているので、ここに届くのは古い結果だけ
            return []
        }
    }

    private mutating func selectCharacter(_ character: Character, context: SelectionContext) -> [HintModeEffect] {
        let typed = context.typed + String(character)
        // 確定は `.confirmed` のときだけ。要素数 1 では空の入力でも `.narrowed` が 1 件になるため（design.md 6.3）
        switch LabelFilter.match(typed, in: context.hints) {
        case .confirmed(let hint):
            state = .idle
            // オーバーレイを消し、キー破棄を解いてからクリックする（F-5.4）
            return [.hideHints, .setKeySuppression(false), .perform(.leftClick, hint.element)]
        case .narrowed(let candidates):
            var next = context
            next.typed = typed
            state = .selecting(next)
            return [.updateHints(visible: Set(candidates.map(\.element.id)), typed: typed)]
        case .noMatch:
            // 一致しない文字は無視し、入力済みの文字列も変えない（暫定 Q-6）
            return []
        }
    }

    private mutating func deleteLastCharacter(context: SelectionContext) -> [HintModeEffect] {
        // 入力が空なら何もしない（暫定 Q-7）
        guard !context.typed.isEmpty else { return [] }
        var next = context
        next.typed.removeLast()
        state = .selecting(next)
        return [.updateHints(visible: Set(next.visibleHints.map(\.element.id)), typed: next.typed)]
    }
}
