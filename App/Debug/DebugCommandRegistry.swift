#if DEBUG
    /// Debug ビルドの起動引数とコマンドの対応表、および起動引数の解釈（N-6.3）。
    ///
    /// 解釈の規則:
    /// - 対象は `--` で始まる引数だけ。`-` 1 つで始まる引数（`-NSDocumentRevisionsDebugMode YES` など、
    ///   Xcode や AppKit が付ける `NSUserDefaults` の引数）と、その値は扱わない。
    /// - コマンドの引数（`commands` のキー）が 1 つだけあれば、そのコマンドを実行する。値は取らない。
    /// - 通常起動のオプション（`normalLaunchOptions`）は `--name=value` の形で受ける。値の検査は
    ///   そのオプションを読む側（例: `EventTapDebugHooks`）が行う。ここでは値が空でないことだけを確かめる。
    /// - それ以外の `--` 引数、コマンドの重複、コマンドと通常起動のオプションの併用はエラーにする
    ///   （打ち間違いを黙って無視すると、通常起動したことに気付けないため）。
    ///
    /// 引数を増やすときは `App/Debug/Commands/` にファイルを足し、`commands` に 1 行足す。
    /// この表の変更は共有ファイルの変更として単独のタスクにする（tasks.md「集約点」）。
    enum DebugCommandRegistry {
        /// 起動引数 → コマンド。コメントは実装を担当するタスク。
        /// 辞書リテラルのキーが重複すると、実行時に初期化で停止する（登録の誤りに気付ける）。
        static let commands: [String: any DebugCommand.Type] = [
            "--show-permission-guide": ShowPermissionGuideCommand.self,  // T32
            "--translate-test": TranslateTestCommand.self,  // T35
            "--dump-windows": DumpWindowsCommand.self,  // T39
            "--ax-selftest": AXSelfTestCommand.self,  // T40
            "--walk-front-app": WalkFrontAppCommand.self,  // T41
            "--collect-once": CollectOnceCommand.self,  // T42
            "--dump-screens": DumpScreensCommand.self,  // T43
            "--overlay-demo": OverlayDemoCommand.self,  // T44 / T45
            "--press-test": PressTestCommand.self,  // T46
            "--click-test": ClickTestCommand.self,  // T47
        ]

        /// 通常起動（`AppDelegate`）のまま有効になるオプション。`--name=value` の形で受ける。
        /// 読むのは各オプションの担当（`--tap-hook` は T33、`--trigger-key` は T34 の `EventTapDebugHooks`）。
        static let normalLaunchOptions: Set<String> = [
            "--tap-hook",
            "--trigger-key",
        ]

        /// 起動引数（`CommandLine.arguments` から実行ファイルのパスを除いたもの）を解釈する。
        static func resolve(arguments: [String]) throws(DebugArgumentError) -> DebugLaunch {
            var requestedCommands: [(argument: String, type: any DebugCommand.Type)] = []
            var optionNames: [String] = []

            for argument in arguments where argument.hasPrefix("--") {
                switch try classify(argument) {
                case .command(let name, let type):
                    requestedCommands.append((name, type))
                case .launchOption(let name):
                    guard !optionNames.contains(name) else { throw .duplicateArgument(name) }
                    optionNames.append(name)
                }
            }

            guard let command = requestedCommands.first else { return .normal }
            guard requestedCommands.count == 1 else {
                throw .multipleCommands(requestedCommands.map(\.argument))
            }
            guard optionNames.isEmpty else {
                throw .commandWithLaunchOptions(command: command.argument, options: optionNames)
            }
            return .command(argument: command.argument, type: command.type)
        }

        private enum ArgumentKind {
            case command(name: String, type: any DebugCommand.Type)
            case launchOption(name: String)
        }

        /// `--` で始まる引数 1 つを、コマンドか通常起動のオプションに分ける。どちらでもなければ投げる。
        private static func classify(_ argument: String) throws(DebugArgumentError) -> ArgumentKind {
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let value = parts.count == 2 ? String(parts[1]) : nil

            if let type = commands[name] {
                guard value == nil else { throw .unexpectedValue(argument: name) }
                return .command(name: name, type: type)
            }
            if normalLaunchOptions.contains(name) {
                guard let value, !value.isEmpty else { throw .missingValue(argument: name) }
                return .launchOption(name: name)
            }
            throw .unknownArgument(name)
        }
    }

    /// 起動引数を解釈した結果。
    enum DebugLaunch {
        /// 通常どおり `AppDelegate` で起動する。
        case normal
        /// `DebugCommandHost` でコマンドを 1 つ実行して終了する。
        case command(argument: String, type: any DebugCommand.Type)
    }

    /// 起動引数の誤り。`App/Main.swift` がログに出して、起動せずに終了コード 1 で終える。
    enum DebugArgumentError: Error, CustomStringConvertible {
        case unknownArgument(String)
        /// コマンドの引数に `=value` が付いている（コマンドは値を取らない）。
        case unexpectedValue(argument: String)
        /// 通常起動のオプションに値がない（`--name` や `--name=`）。
        case missingValue(argument: String)
        case duplicateArgument(String)
        case multipleCommands([String])
        case commandWithLaunchOptions(command: String, options: [String])

        var description: String {
            switch self {
            case .unknownArgument(let argument):
                "不明な引数です: \(argument)（使える引数: \(Self.knownArguments)）"
            case .unexpectedValue(let argument):
                "\(argument) は値を取りません"
            case .missingValue(let argument):
                "\(argument) には値が必要です（\(argument)=<値> の形で指定します）"
            case .duplicateArgument(let argument):
                "\(argument) が複数回指定されています"
            case .multipleCommands(let arguments):
                "コマンドは 1 つだけ指定できます: \(arguments.joined(separator: " "))"
            case .commandWithLaunchOptions(let command, let options):
                "\(command) は通常起動のオプションと併用できません: \(options.joined(separator: " "))"
            }
        }

        private static var knownArguments: String {
            let commands = DebugCommandRegistry.commands.keys.sorted()
            let options = DebugCommandRegistry.normalLaunchOptions.sorted().map { "\($0)=<値>" }
            return (commands + options).joined(separator: " ")
        }
    }
#endif
