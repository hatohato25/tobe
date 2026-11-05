import Foundation
import ServiceManagement

/// ログイン時の起動の状態（design.md 12.3）。`SMAppService.Status` の既知の 4 値に対応する。
enum LaunchAtLoginStatus: Sendable, Equatable {
    /// 登録済みで、ログイン時に起動される。トグルはオン。
    case enabled
    /// 登録されていない（未登録、または解除済み）。トグルはオフ（既定。暫定 Q-22）。
    case notRegistered
    /// 登録済みだが、システム設定の「ログイン項目」でユーザーの承認が要る（S-4.3）。
    case requiresApproval
    /// サービスが見つからない。一度も登録していないアプリでも返るので、オンにしようとしたときだけエラーとして表示する。
    case notFound
}

/// ServiceManagement が返したエラーの種類（`SMErrors.h` の `kSMError…` に対応）。
enum ServiceManagementErrorKind: Int, Sendable, Equatable {
    case internalFailure = 2
    case invalidSignature = 3
    case authorizationFailure = 4
    case toolNotValid = 5
    case jobNotFound = 6
    case serviceUnavailable = 7
    case jobPlistNotFound = 8
    case jobMustBeEnabled = 9
    case invalidPlist = 10
    case launchDeniedByUser = 11
    case alreadyRegistered = 12
}

/// `register()` / `unregister()` が投げた `NSError` を、`Sendable` な値に写したもの。
///
/// 設定画面にはそのまま表示し（S-4.4）、ログには domain と code を残す。
/// `NSError` は `Sendable` ではなく、`userInfo` に任意の値が入りうるので、必要な値だけを取り出して持つ。
struct ServiceManagementFailure: Sendable, Equatable {
    let domain: String
    let code: Int
    /// 分類できたときの種類。domain が `SMAppServiceErrorDomain` 以外、または未知の code のときは `nil`
    /// （他の domain の code は意味が違うので、無理に既知の種類へ寄せない）。
    let kind: ServiceManagementErrorKind?
    /// システムが付けた説明文。ユーザーの入力や要素のテキストは含まない。
    let localizedDescription: String

    init(_ error: any Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        kind = nsError.domain == SMAppServiceErrorDomain ? ServiceManagementErrorKind(rawValue: nsError.code) : nil
        localizedDescription = nsError.localizedDescription
    }
}

/// ログイン時の起動の操作で起きたエラー。
enum LaunchAtLoginError: Error, Sendable, Equatable {
    /// `SMAppService.Status` に、このビルドが知らない値が返った。どの表示が正しいか分からないので、既定値にせずエラーにする。
    case unknownStatus(rawValue: Int)
    /// `register()` が失敗した（S-4.4）。
    case registerFailed(ServiceManagementFailure)
    /// `unregister()` が失敗した（S-4.4）。
    case unregisterFailed(ServiceManagementFailure)
}

/// `SMAppService.mainApp` によるログイン時の起動（S-4.1〜S-4.4、design.md 12.3）。
///
/// - 状態は保存しない。毎回 `SMAppService.mainApp.status` を読む（D-22）。ユーザーがシステム設定で外したときに、
///   表示と実態がずれないようにするため（S-4.2）。設定画面は、開いたときとアプリがアクティブになったときに `status()` を呼び直す。
/// - 設定画面（SwiftUI）から呼ぶので `@MainActor` にする。`register()` / `unregister()` は同期 API で、すぐに返る。
/// - オンとオフは別のメソッドにする（Bool の引数で分けない）。どちらも、操作の後に読み直した状態を返す。
///   `register()` が成功しても `.requiresApproval` になることがあるため、呼び出し側は戻り値で表示を決める。
@MainActor
struct LaunchAtLoginService {
    /// 現在の状態を `SMAppService` から読む。
    func status() throws(LaunchAtLoginError) -> LaunchAtLoginStatus {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            Log.settings.error("ログイン項目の状態が未知の値: \(status.rawValue, privacy: .public)")
            throw .unknownStatus(rawValue: status.rawValue)
        }
    }

    /// ログイン時に起動するように登録する（S-4.1）。登録後に読み直した状態を返す。
    ///
    /// 既に `.enabled` のときは何もしない。`register()` は登録済みだと `alreadyRegistered` を投げるため、
    /// 状態が既に目的どおりなのにエラーを表示しないようにする。
    /// `.requiresApproval` のときは登録をやり直す（承認待ちの登録は残るので、結果は再び `.requiresApproval` になりうる）。
    func enable() throws(LaunchAtLoginError) -> LaunchAtLoginStatus {
        let before = try status()
        guard before != .enabled else { return before }
        do {
            try SMAppService.mainApp.register()
        } catch {
            let failure = ServiceManagementFailure(error)
            Self.logFailure(operation: "register", failure)
            throw .registerFailed(failure)
        }
        let after = try status()
        Log.settings.notice("ログイン項目に登録した。状態: \(String(describing: after), privacy: .public)")
        return after
    }

    /// ログイン時の起動の登録を解除する（S-4.1）。解除後に読み直した状態を返す。
    ///
    /// 既に `.notRegistered` のときは何もしない。`unregister()` は未登録だと `jobNotFound` を投げるため。
    /// `.notFound` のときも解除を試み、失敗すればそのエラーを返す（黙って成功扱いにしない）。
    func disable() throws(LaunchAtLoginError) -> LaunchAtLoginStatus {
        let before = try status()
        guard before != .notRegistered else { return before }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            let failure = ServiceManagementFailure(error)
            Self.logFailure(operation: "unregister", failure)
            throw .unregisterFailed(failure)
        }
        let after = try status()
        Log.settings.notice("ログイン項目の登録を解除した。状態: \(String(describing: after), privacy: .public)")
        return after
    }

    /// システム設定の「ログイン項目」を開く。`.requiresApproval` のときに承認を案内するボタンから呼ぶ（S-4.3）。
    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func logFailure(operation: StaticString, _ failure: ServiceManagementFailure) {
        // domain・code・説明文はシステムの固定の語彙なので public にする（ユーザーの入力は含まない）
        Log.settings.error(
            """
            ログイン項目の \(String(describing: operation), privacy: .public) に失敗: \
            domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public) \
            kind=\(String(describing: failure.kind), privacy: .public) \
            description=\(failure.localizedDescription, privacy: .public)
            """
        )
    }
}
