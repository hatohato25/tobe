import Foundation

/// 収集した要素の識別子。App 側の `ElementHandleRegistry` が `AXUIElement` と対応付ける。
public struct ElementID: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// ウィンドウの識別子。`CGWindowID` と同じ値を持つ。
public struct WindowID: Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// プロセスの識別子。`pid_t` と同じ値を持つ。
public struct ProcessID: Hashable, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
}

/// 画面の識別子。`NSScreen.screens` の添字で、画面構成が変わるたびに作り直す（永続化しない）。
public struct ScreenID: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// ヒントの対象として収集した 1 つの要素。
public struct CollectedElement: Equatable, Sendable {
    public let id: ElementID
    public let windowID: WindowID
    public let frame: GlobalRect
    /// `"AXButton"` などの AX ロール。ログと将来の要素の種類による絞り込み（F-11）に使う。
    /// 要素のタイトルや値は個人情報を含みうるため持たない。
    public let role: String

    public init(id: ElementID, windowID: WindowID, frame: GlobalRect, role: String) {
        self.id = id
        self.windowID = windowID
        self.frame = frame
        self.role = role
    }
}
