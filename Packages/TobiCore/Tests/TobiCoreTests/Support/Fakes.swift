import Synchronization

@testable import TobiCore

/// フェイクのポートが受けた呼び出しを、ポートをまたいで呼ばれた順に記録する。
///
/// 確定のときの「`hide` → キー破棄の解除 → `perform`」のように、別々のポートの呼び出しの順序を確かめるために使う。
final class CallJournal: Sendable {
    enum Entry: Equatable, Sendable {
        case setSuppressing(Bool)
        case collect
        case show(count: Int)
        case update(Set<ElementID>)
        case hide
        case perform(HintAction, ElementID)
        case playFailure
        case log(HintModeLogEvent)
    }

    private let recorded = Mutex<[Entry]>([])

    var entries: [Entry] {
        recorded.withLock { $0 }
    }

    func append(_ entry: Entry) {
        recorded.withLock { $0.append(entry) }
    }
}

/// 呼ばれると、用意された結果を返す `ElementCollecting`。
///
/// 結果が用意されていなければ、`respond(with:)` で渡されるまで待つ（収集中の Esc や、遅れて届く結果を再現するため）。
/// Task のキャンセルは記録するだけで、待つのはやめない（キャンセルに応じない収集から、古い結果が後で届く場合を再現する）。
final class FakeCollector: ElementCollecting {
    typealias Outcome = Result<CollectionResult, CollectionError>

    private struct State {
        var queued: [Outcome] = []
        var waiting: [CheckedContinuation<Outcome, Never>] = []
        var waitingWatchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var deadlines: [ContinuousClock.Instant] = []
        var cancelledCallCount = 0
    }

    private let journal: CallJournal
    private let state = Mutex(State())

    init(journal: CallJournal) {
        self.journal = journal
    }

    /// 受け取った期限（呼ばれた順）。
    var deadlines: [ContinuousClock.Instant] {
        state.withLock { $0.deadlines }
    }

    /// 待っている間に Task がキャンセルされた呼び出しの数。
    var cancelledCallCount: Int {
        state.withLock { $0.cancelledCallCount }
    }

    /// 次の呼び出しの結果を渡す。待っている呼び出しがあれば、いちばん先に呼ばれたものに返す。
    func respond(with outcome: Outcome) {
        state.withLock { state in
            if state.waiting.isEmpty {
                state.queued.append(outcome)
            } else {
                state.waiting.removeFirst().resume(returning: outcome)
            }
        }
    }

    /// 結果を待っている呼び出しが `count` 件以上になるまで待つ。
    func waitUntilWaiting(count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { state in
                if state.waiting.count >= count {
                    continuation.resume()
                } else {
                    state.waitingWatchers.append((count, continuation))
                }
            }
        }
    }

    func collect(deadline: ContinuousClock.Instant) async throws(CollectionError) -> CollectionResult {
        journal.append(.collect)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                state.withLock { state in
                    state.deadlines.append(deadline)
                    if state.queued.isEmpty {
                        state.waiting.append(continuation)
                        Self.resumeSatisfiedWatchers(in: &state)
                    } else {
                        continuation.resume(returning: state.queued.removeFirst())
                    }
                }
            }
        } onCancel: {
            state.withLock { $0.cancelledCallCount += 1 }
        }
        return try outcome.get()
    }

    private static func resumeSatisfiedWatchers(in state: inout State) {
        let waitingCount = state.waiting.count
        let satisfied = state.waitingWatchers.filter { $0.count <= waitingCount }
        state.waitingWatchers.removeAll { $0.count <= waitingCount }
        for watcher in satisfied {
            watcher.continuation.resume()
        }
    }
}

/// 決めた結果を返す `ActionPerforming`。
final class FakePerformer: ActionPerforming {
    private let journal: CallJournal
    private let outcome: Result<ActionMethod, ActionError>

    init(journal: CallJournal, outcome: Result<ActionMethod, ActionError>) {
        self.journal = journal
        self.outcome = outcome
    }

    func perform(_ action: HintAction, on element: CollectedElement) async throws(ActionError) -> ActionMethod {
        journal.append(.perform(action, element.id))
        return try outcome.get()
    }
}

/// 表示の指示を記録する `HintOverlayPresenting`。
@MainActor
final class FakeOverlay: HintOverlayPresenting {
    struct Shown: Equatable {
        let placements: [HintPlacement]
        let appearance: LabelAppearance
    }

    private let journal: CallJournal
    private(set) var shown: [Shown] = []

    init(journal: CallJournal) {
        self.journal = journal
    }

    func show(_ placements: [HintPlacement], appearance: LabelAppearance) {
        shown.append(Shown(placements: placements, appearance: appearance))
        journal.append(.show(count: placements.count))
    }

    func update(visibleIDs: Set<ElementID>) {
        journal.append(.update(visibleIDs))
    }

    func hide() {
        journal.append(.hide)
    }
}

/// キー破棄の切り替えを記録する `KeySuppressionGate`。
final class FakeGate: KeySuppressionGate {
    private let journal: CallJournal

    init(journal: CallJournal) {
        self.journal = journal
    }

    func setSuppressing(_ suppressing: Bool) {
        journal.append(.setSuppressing(suppressing))
    }
}

/// 失敗の音を記録する `FeedbackPlaying`。
@MainActor
final class FakeFeedback: FeedbackPlaying {
    private let journal: CallJournal

    init(journal: CallJournal) {
        self.journal = journal
    }

    func playFailure() {
        journal.append(.playFailure)
    }
}

/// 決めた画面の一覧を返す `ScreenGeometryProviding`。
@MainActor
final class FakeScreens: ScreenGeometryProviding {
    var screens: [ScreenGeometry]

    init(screens: [ScreenGeometry]) {
        self.screens = screens
    }

    func currentScreens() -> [ScreenGeometry] {
        screens
    }
}
