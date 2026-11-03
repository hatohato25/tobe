import ApplicationServices

/// `AXUIElement` を、スレッドをまたいで受け渡せるようにする包み（design.md 4 章、D-23）。
///
/// `@unchecked Sendable` にする理由:
/// - `AXUIElement` は CF の型で、Swift 6 では `Sendable` ではない。だが参照自体は不変で、AX の API は
///   どのスレッドから呼んでもよい（呼び出しはその場で同期の IPC になるだけで、参照に可変の状態を持たない）。
/// - アプリ単位の並列収集（design.md 8.5、D-12）では、GCD のキューで読んだ要素を MainActor の
///   操作（`AXPress`）へ渡すため、`Sendable` でないと受け渡せない。
/// - 唯一の例外はメッセージングのタイムアウトで、参照ごとの設定（V-3）がこの参照に結び付く。設定は
///   プロセス内の値の書き換えで、どのスレッドから行っても壊れない（最後に書いた値が効く）。
///
/// この包みは App の Accessibility 以下（と、それを使う Debug コマンド）でだけ使い、TobiCore には出さない
/// （TobiCore は `AccessibilityTreeSource.Node` として型を知らずに扱う）。
struct AXElementRef: @unchecked Sendable {
    let raw: AXUIElement

    /// アプリケーションの要素（AX ツリーの根）。プロセスが存在しなくても生成は成功し、読み取りで失敗する。
    static func application(pid: pid_t) -> AXElementRef {
        AXElementRef(raw: AXUIElementCreateApplication(pid))
    }

    /// システム全体の要素。`AXUIElementSetMessagingTimeout` に渡すと、要素ごとの設定をしていない
    /// すべての参照の既定値になる（design.md 8.5、D-29）。
    static func systemWide() -> AXElementRef {
        AXElementRef(raw: AXUIElementCreateSystemWide())
    }
}
