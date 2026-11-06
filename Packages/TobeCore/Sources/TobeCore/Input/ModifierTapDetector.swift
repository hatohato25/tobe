import Foundation

/// 起動キーの単独タップを判定する状態機械（spec.md 4.4、design.md 3.4）。
///
/// 起動キーを押してから、他の入力をせずに `maxTapDuration` 以内（ちょうども含む。暫定 Q-1）に離したときだけ
/// `.tapped` を返す。同期は持たない。タップスレッドと共有する場合の保護は App 側（`TapContext` の `Mutex`）が行う。
public struct ModifierTapDetector: Sendable {
    private enum State: Equatable, Sendable {
        case idle
        /// 起動キーが押されており、まだ他の入力がない
        case pressed(since: Timestamp)
        /// 押されている間に他の入力があった。離されるまで起動しない
        case invalidated
    }

    /// 起動キー（S-1）。変更すると判定の途中の状態を捨てる。
    /// 押下中に切り替えると、旧キーの解放を新キーの判定に持ち込んでしまうため。
    public var triggerKey: TriggerKey {
        didSet { reset() }
    }

    private let maxTapNanoseconds: UInt64
    private var state: State = .idle

    /// - Parameter maxTapDuration: 押してから離すまでの上限。0 以上であること。
    public init(triggerKey: TriggerKey, maxTapDuration: Duration = .milliseconds(300)) {
        precondition(maxTapDuration >= .zero, "maxTapDuration must not be negative")
        self.triggerKey = triggerKey
        let (seconds, attoseconds) = maxTapDuration.components
        // components は 0 以上を確認済み。1 ns = 10^9 as
        self.maxTapNanoseconds = UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }

    public mutating func handle(_ input: TapInput) -> TapDetection {
        switch (state, input) {
        case (.idle, .flagsChanged(let keyCode, let flags, let time)):
            guard keyCode == triggerKey.keyCode, flags.contains(triggerKey.deviceFlag) else { return .none }
            state = otherModifiersHeld(in: flags) ? .invalidated : .pressed(since: time)
            return .none

        case (.pressed(let pressedAt), .flagsChanged(let keyCode, let flags, let time)):
            guard keyCode == triggerKey.keyCode else {
                // 他の修飾キー（Caps Lock キー 0x39 の押下も含む）の変化。F-1.4
                state = .invalidated
                return .none
            }
            // 押下中にもう一度押下が届くことは通常ないが、届いても押下の時刻は最初のものを保つ
            guard !flags.contains(triggerKey.deviceFlag) else { return .none }
            state = .idle
            return isWithinTapDuration(from: pressedAt, to: time) ? .tapped : .none

        case (.pressed, .keyDown), (.pressed, .pointerDown):
            state = .invalidated
            return .none

        case (.invalidated, .flagsChanged(let keyCode, let flags, _)):
            if keyCode == triggerKey.keyCode, !flags.contains(triggerKey.deviceFlag) {
                state = .idle
            }
            return .none

        case (.idle, .keyDown), (.idle, .pointerDown), (.invalidated, .keyDown), (.invalidated, .pointerDown):
            return .none
        }
    }

    /// 判定の途中の状態を捨てる。タップが OS に無効化されて解放を取りこぼした可能性があるときに App が呼ぶ（design.md 7.2）。
    public mutating func reset() {
        state = .idle
    }

    /// 起動キーを押した時点で、他の修飾キーが押されているか（F-1.4、暫定 Q-2）。
    ///
    /// 押下 / 解放の判定と同じく、同種キーの左右はデバイス依存ビットで区別する（D-5）。
    /// `alphaShift` は Caps Lock のトグル状態なので見ない。見ると Caps Lock がオンの間ずっと起動できなくなる。
    private func otherModifiersHeld(in flags: ModifierFlags) -> Bool {
        let blocking: ModifierFlags =
            switch triggerKey {
            case .rightCommand: [.shift, .control, .secondaryFn, .option, .deviceLeftCommand]
            case .rightOption: [.shift, .control, .secondaryFn, .command, .deviceLeftOption]
            }
        return !flags.isDisjoint(with: blocking)
    }

    private func isWithinTapDuration(from start: Timestamp, to end: Timestamp) -> Bool {
        // 時刻は単調増加（D-6）なので end < start は起きない。起きた場合は時刻が信用できないので起動しない
        guard end >= start else { return false }
        return end.nanoseconds - start.nanoseconds <= maxTapNanoseconds
    }
}
