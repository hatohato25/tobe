#if DEBUG
    import Foundation
    import TobeCore

    /// Debug ビルドだけのイベントタップの確認用フック（T34。手動確認は T38）。Release には含めない。
    ///
    /// 通常起動のオプション（`DebugCommandRegistry.normalLaunchOptions` に登録済み）を、ここで自分で読む:
    /// - `--tap-hook=timeout`: 起動キーの単独タップを検出したコールバックで `timeoutHookSleep` 秒止まり、
    ///   OS に `tapDisabledByTimeout` を起こさせる（F-1.10 の再有効化の確認）。
    /// - `--tap-hook=disable`: 起動キーの単独タップを検出したら `CGEvent.tapEnable(tap:enable: false)` を呼ぶ。
    ///   通知のない無効化を、ウォッチドッグ（`EventTapWatchdog`）が 1 秒以内に再有効化することの確認。
    /// - `--trigger-key=right-option` / `right-command`: `EventTapController` の生成時に `updateTriggerKey` を呼ぶ
    ///   （S-1.2 の下準備。設定画面（T52）ができる前に右 ⌥ を試すため）。
    ///
    /// 値の誤りは、`App/Main.swift` が不明な引数を扱うのと同じく、ログに出して終了する
    /// （打ち間違いを黙って無視すると、フックなしで確認したことに気付けないため）。
    enum EventTapDebugHooks {
        /// `--tap-hook` の値。
        enum TapHook: String, CaseIterable, Sendable {
            case timeout
            case disable
        }

        /// 起動引数から読んだフックの設定。
        struct Options: Equatable, Sendable {
            var tapHook: TapHook?
            var triggerKey: TriggerKey?
        }

        /// 起動引数の値の誤り。
        enum ParseError: Error, Equatable, CustomStringConvertible {
            case invalidValue(option: String, value: String, allowed: [String])

            var description: String {
                switch self {
                case .invalidValue(let option, let value, let allowed):
                    "\(option) の値が不正です: \(value)（使える値: \(allowed.joined(separator: " "))）"
                }
            }
        }

        /// `--tap-hook=timeout` でコールバックを止める時間（秒）。OS がタイムアウトと見なす時間（約 1 秒）より長くする。
        static let timeoutHookSleep: TimeInterval = 1.5

        private static let tapHookOption = "--tap-hook"
        private static let triggerKeyOption = "--trigger-key"

        /// `--trigger-key` の値と起動キー。値は `DebugCommandRegistry` の他の引数に合わせてケバブケースにする。
        private static let triggerKeyValues: [(value: String, key: TriggerKey)] = [
            ("right-command", .rightCommand),
            ("right-option", .rightOption),
        ]

        /// このプロセスの起動引数から読んだ設定。最初に使われたとき（`EventTapController` の生成時）に 1 回だけ読む。
        static let options: Options = loadOptions()

        /// 起動引数（実行ファイルのパスを除く）からフックの設定を読む。重複と空の値は `DebugCommandRegistry` が
        /// 起動時に弾いているので、ここでは値の種類だけを確かめる。
        static func parse(arguments: [String]) throws(ParseError) -> Options {
            var options = Options()
            for argument in arguments {
                let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let name = String(parts[0])
                let value = String(parts[1])
                switch name {
                case tapHookOption:
                    guard let hook = TapHook(rawValue: value) else {
                        throw .invalidValue(option: name, value: value, allowed: TapHook.allCases.map(\.rawValue))
                    }
                    options.tapHook = hook
                case triggerKeyOption:
                    guard let entry = triggerKeyValues.first(where: { $0.value == value }) else {
                        throw .invalidValue(option: name, value: value, allowed: triggerKeyValues.map(\.value))
                    }
                    options.triggerKey = entry.key
                default:
                    continue
                }
            }
            return options
        }

        private static func loadOptions() -> Options {
            let options: Options
            do {
                options = try parse(arguments: Array(ProcessInfo.processInfo.arguments.dropFirst()))
            } catch {
                Log.debug.error("起動引数が不正なため終了します: \(error.description, privacy: .public)")
                exit(EXIT_FAILURE)
            }
            if let tapHook = options.tapHook {
                Log.debug.notice("Debug: --tap-hook=\(tapHook.rawValue, privacy: .public) が有効")
            }
            if let triggerKey = options.triggerKey {
                Log.debug.notice("Debug: --trigger-key で起動キーを \(triggerKey.rawValue, privacy: .public) にする")
            }
            return options
        }
    }
#endif
