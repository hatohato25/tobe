import os

/// アプリ全体で使う `Logger` の集約点（design.md 14 章）。
///
/// 使い方: `Log.hotkey.notice("イベントタップを作成した")`
///
/// - subsystem は Debug・Release とも `io.github.hatohato25.tobi`（Debug のバンドル ID `…tobi.debug` は使わない）。
///   ビルドの種類によらずログの絞り込み条件（`subsystem:io.github.hatohato25.tobi`）を共通にするため。
/// - 要素のタイトル・値、ユーザーが打った文字はログに出さない。出すのはロール、件数、時間、エラーの種類だけにする。
///   文字列を補間するときは、固定の語彙（エラーの case 名、ロールなど）にだけ `privacy: .public` を付ける。
///
/// `Logger` は `Sendable` なので、`static let` で持ってどのスレッド（イベントタップのスレッドや GCD のキュー）からでも使える。
enum Log {
    /// ログの subsystem。`Signposts` も同じ値を使う。
    static let subsystem = "io.github.hatohato25.tobi"

    /// アプリの組み立て（モジュールの開始・停止）。既存の `AppDelegate` の category と同じ値。
    static let app = Logger(subsystem: subsystem, category: "App")
    /// Debug ビルドの開発用コマンド（`App/Debug/`）。
    static let debug = Logger(subsystem: subsystem, category: "debug")
    /// イベントタップの作成・失敗・無効化と再有効化（理由付き）、起動キーの変更、キーの変換。
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    /// 収集にかかった時間、アプリごとのヒット数、`CollectionDiagnostic`。
    static let collector = Logger(subsystem: subsystem, category: "collector")
    /// 操作の方法（`axPress` / `mouseClick`）、失敗したときの AXError。
    static let action = Logger(subsystem: subsystem, category: "action")
    /// オーバーレイのパネルの作成・表示・画面構成の変更。
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    /// アクセシビリティ権限の状態の変化。
    static let permission = Logger(subsystem: subsystem, category: "permission")
    /// `SettingsIssue`、ログイン項目の登録エラー。
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
