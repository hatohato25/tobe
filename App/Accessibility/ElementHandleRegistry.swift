import Synchronization
import TobeCore

/// 収集した要素の `ElementID` と AX の参照（`AXElementRef`）の対応表（design.md 6 章の表、13 章、F-5）。
///
/// - `AXElementCollector` が収集のたびに `beginCollection()` で前の対応を消し、走査が終わったら `register(_:for:)` で
///   新しい対応を入れる。`AXActionPerformer` は `lookup` で `ElementID` から参照を引く。
/// - `ElementID` は対応表を作り直しても使い回さず、増やし続ける。前のセッションの `ElementID` で引いても、別の要素が
///   返らずに `nil`（→ `ActionError.elementNotFound`）になるようにするため。
/// - 世代（`Generation`）: 収集の途中で次の収集が始まった、またはセッションが終わって `removeAll()` された場合は、
///   古い収集の `register(_:for:)` を受け付けない（古い参照が新しいセッションに混ざるのを防ぐ）。
///
/// スレッド: 収集（Swift Concurrency の Task）と操作（GCD のキュー）の両方から呼ばれるので、中身を `Mutex` で守る。
/// どのメソッドもロックを短く持つだけで、IPC はしない。
final class ElementHandleRegistry: Sendable {
    /// 収集 1 回を表す世代。`beginCollection()` が返し、`register(_:for:)` に渡す。
    struct Generation: Equatable, Sendable {
        fileprivate let rawValue: UInt64
    }

    private struct State {
        var generation: UInt64 = 0
        var nextID = 0
        var handles: [ElementID: AXElementRef] = [:]
    }

    private let state = Mutex(State())

    init() {}

    /// 新しい収集を始める。前の収集の対応を消し、それ以前の世代の `register(_:for:)` を受け付けなくする。
    func beginCollection() -> Generation {
        state.withLock { state in
            state.generation += 1
            state.handles.removeAll()
            return Generation(rawValue: state.generation)
        }
    }

    /// 収集した要素を登録し、同じ順に `ElementID` を返す。
    ///
    /// - Returns: 登録した `ElementID`（`elements` と同じ順・同じ数）。`generation` が古い（その後に別の収集が
    ///   始まった、または `removeAll()` された）ときは何も登録せずに `nil`。呼び出し側は収集を取り消し扱いにする。
    func register(_ elements: [AXElementRef], for generation: Generation) -> [ElementID]? {
        state.withLock { state in
            guard state.generation == generation.rawValue else { return nil }
            var ids: [ElementID] = []
            ids.reserveCapacity(elements.count)
            for element in elements {
                let id = ElementID(rawValue: state.nextID)
                state.nextID += 1
                state.handles[id] = element
                ids.append(id)
            }
            return ids
        }
    }

    /// `ElementID` に対応する参照。対応がない（古いセッションの要素、消した後）ときは `nil`。
    func element(for id: ElementID) -> AXElementRef? {
        state.withLock { $0.handles[id] }
    }

    /// すべての対応を消す（ヒントモードのセッションが終わったとき。T48）。収集の途中なら、その収集の登録も受け付けない。
    func removeAll() {
        state.withLock { state in
            state.generation += 1
            state.handles.removeAll()
        }
    }

    /// `AXActionPerformer(lookUpElement:)` に渡す検索。GCD のキューから呼ばれてよい。
    var lookup: AXActionPerformer.ElementLookup {
        { [self] id in element(for: id) }
    }
}
