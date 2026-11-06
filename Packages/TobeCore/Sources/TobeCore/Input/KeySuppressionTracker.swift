import Foundation

/// キーイベントをアプリへ渡すか破棄するかを決め、「破棄した keyDown」を記録する（design.md 7.3、F-7.1〜F-7.3）。
///
/// 純粋な値型で、スレッド間の保護は持たない。タップスレッドと MainActor から触るときは、
/// App 側の `TapContext` が `Synchronization.Mutex` で守る（T33）。
///
/// 規則（design.md 7.3）:
///
/// | イベント | 条件 | 結果 |
/// |----------|------|------|
/// | keyDown | isSuppressing | suppress。keyCode を「破棄済み」に記録する |
/// | keyDown | !isSuppressing | pass |
/// | keyUp | 「破棄済み」にある | suppress。記録から消す（ヒントモードの終了後でも） |
/// | keyUp | 記録にない | pass |
/// | flagsChanged | — | 常に pass（記録しない） |
///
/// 表の規則に加えて、アプリに渡した keyDown も記録する。アプリ側でキーが押されたままにならないようにするため（F-7.2）:
/// - ヒントモードの前から押されていたキーのリピートがヒントモード中に届いた場合、その keyDown は破棄するが
///   「破棄済み」には記録しない。記録すると、アプリが受け取った最初の keyDown に対応する keyUp まで破棄してしまう。
/// - アプリに渡した keyDown は「破棄済み」の記録を消す。タップが無効になっている間に keyUp を取りこぼすと
///   記録が残り、次にアプリへ渡したキーの keyUp を誤って破棄してしまうため。
///
/// タップが無効化から復旧しても、この記録は捨てない（design.md 7.4）。
public struct KeySuppressionTracker: Equatable, Sendable {
    /// `disposition(for:keyCode:isSuppressing:)` に渡すイベントの種類。
    public enum EventKind: Equatable, Sendable {
        case keyDown
        case keyUp
        /// 修飾キーの変化。常に pass（F-7.3）。表の規則をこの型の中で完結させるために受け付ける。
        case flagsChanged
    }

    /// イベントの扱い。
    public enum Disposition: Equatable, Sendable {
        /// アプリへそのまま渡す。
        case pass
        /// 破棄する（コールバックで `nil` を返す）。
        case suppress
    }

    /// 破棄した keyDown のうち、まだ keyUp が届いていない keyCode。
    private var suppressedKeyCodes: Set<UInt16> = []
    /// アプリへ渡した keyDown のうち、まだ keyUp が届いていない keyCode。
    private var passedKeyCodes: Set<UInt16> = []

    public init() {}

    /// イベントの扱いを決め、記録を更新する。
    ///
    /// - Parameters:
    ///   - kind: イベントの種類。
    ///   - keyCode: 仮想キーコード。
    ///   - isSuppressing: キー破棄が ON か（ヒントモード中か）。
    public mutating func disposition(for kind: EventKind, keyCode: UInt16, isSuppressing: Bool) -> Disposition {
        switch kind {
        case .keyDown:
            if isSuppressing {
                // 前から押されていたキーのリピートは破棄するが記録しない（型のコメントを参照）
                if !passedKeyCodes.contains(keyCode) {
                    suppressedKeyCodes.insert(keyCode)
                }
                return .suppress
            }
            suppressedKeyCodes.remove(keyCode)
            passedKeyCodes.insert(keyCode)
            return .pass
        case .keyUp:
            // isSuppressing は見ない。ヒントモードの終了後に届いた keyUp も、記録があれば破棄する（F-7.1）
            if suppressedKeyCodes.remove(keyCode) != nil {
                return .suppress
            }
            passedKeyCodes.remove(keyCode)
            return .pass
        case .flagsChanged:
            return .pass
        }
    }
}
