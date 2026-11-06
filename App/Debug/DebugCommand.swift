#if DEBUG
    /// Debug ビルドの起動引数で実行する、開発用のコマンド（N-6.3）。
    ///
    /// 起動引数との対応は `DebugCommandRegistry` が持つ。コマンドの中身は各タスクが
    /// `App/Debug/Commands/` の自分のファイルだけを編集して書く。
    ///
    /// `run()` が戻ったら `DebugCommandHost` が終了コード 0 でプロセスを終える。投げたら終了コード 1 で終える。
    /// 表示し続けるコマンド（オーバーレイのデモなど）は、戻らずに待ち続けてよい（Ctrl-C などで止める）。
    /// ログは `Logger(subsystem: "io.github.hatohato25.tobe", category:)` に出す。要素のタイトルなど
    /// 画面の内容は出さない（design.md 14）。
    /// `Sendable` は、型の対応表（`DebugCommandRegistry.commands`）を `static let` で持つために要る
    /// （`@MainActor` の型はもともと `Sendable` なので、実装側の負担はない）。
    @MainActor
    protocol DebugCommand: Sendable {
        /// `DebugCommandRegistry` が引数なしで生成する。依存はコマンドの中で組み立てる。
        init()

        func run() async throws
    }

    /// コマンドの空実装が投げるエラー。
    enum DebugCommandError: Error, CustomStringConvertible {
        /// 担当タスクがまだコマンドを実装していない。黙って成功扱いにしないために投げる。
        case notImplemented(argument: String, task: String)

        var description: String {
            switch self {
            case .notImplemented(let argument, let task):
                "\(argument) は未実装です（\(task) で実装予定）"
            }
        }
    }
#endif
