import CoreGraphics
import Foundation
import TobeCore

/// `CGWindowListCopyWindowInfo` の結果を分類した一覧（design.md 8.1・8.6）。
///
/// どちらの一覧も `CGWindowList` の並び順（前面から）で、`zIndex` の昇順。
/// `traversalTargets` の各要素は `occlusionWindows` にも同じ値で入っている。
struct WindowListSnapshot: Equatable, Sendable {
    /// 走査の対象: レイヤー 0、所有者が Tobe 以外、`kCGWindowAlpha > 0`（design.md 8.1 手順 2）。
    /// メニューバーと開いているメニューは含めない（収集側が `menuBarWindows` / `popUpMenuWindows(ownedBy:)` から
    /// 別の根として加える。T58）。
    let traversalTargets: [WindowInfo]
    /// 遮蔽の判定（`OcclusionFilter`）に渡す全レイヤーのウィンドウ。
    /// `kCGWindowAlpha == 0` のウィンドウと Tobe 自身のウィンドウは除いてある。`OcclusionFilter` は alpha を見ずに
    /// zIndex だけで前後を決めるため、入れると見えないウィンドウ（オーバーレイなど）で要素を遮蔽と誤判定する（T22）。
    let occlusionWindows: [WindowInfo]
    /// どちらの一覧からも除いた、画面共有や画面収録の重ねウィンドウの数（D-33）。
    let ignoredOverlayCount: Int
    /// パースできずにスキップした項目（`windowListEntrySkipped`）。呼び出し側がログに出す。
    let diagnostics: [CollectionDiagnostic]
}

extension WindowListSnapshot {
    /// メニューバーのウィンドウのレイヤー（`kCGMainMenuWindowLevel`）。
    static let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    /// 開いているメニュー（サブメニュー・コンテキストメニューを含む）のウィンドウのレイヤー（`kCGPopUpMenuWindowLevel`）。
    static let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// メニューバーのウィンドウ（前面から順。ディスプレイごとに 1 枚ありうる）。
    ///
    /// 所有者は前面のアプリではなく WindowServer なので、所有者では絞らない（macOS 27 の実機で確認）。
    /// 前面のアプリの `AXMenuBar` と frame で対応付けるのは収集側（design.md 8.1 手順 2、8.6）。
    var menuBarWindows: [WindowInfo] {
        occlusionWindows.filter { $0.layer == Self.mainMenuLayer }
    }

    /// `pid` が所有する、開いているメニューのウィンドウ（前面から順。design.md 8.1 手順 2、D-31）。
    ///
    /// ほかのアプリ（メニューバー右側のステータスアイテムなど）のメニューは走査しないので含めない（F-2.16）。
    /// 遮蔽の判定には、所有者によらず `occlusionWindows` のまま使う。
    func popUpMenuWindows(ownedBy pid: ProcessID) -> [WindowInfo] {
        occlusionWindows.filter { $0.layer == Self.popUpMenuLayer && $0.ownerPID == pid }
    }
}

/// `CGWindowListCopyWindowInfo` の CF の辞書を `WindowInfo` に変換し、走査の対象と遮蔽の判定用に分ける。
///
/// CF の値はすべて条件付きキャストで読み、型が合わない・キーがない項目は黙って捨てずに
/// `CollectionDiagnostic.windowListEntrySkipped(reason:)` として記録する。
/// 理由の文字列は固定の語彙（項目の位置とキー名）だけにし、ウィンドウ名や所有アプリ名は入れない（design.md 14）。
enum WindowListParser {
    /// - Parameters:
    ///   - entries: `CGWindowListCopyWindowInfo` が返した配列（前面から順）。
    ///   - ownPID: Tobe 自身のプロセス。このプロセスのウィンドウはどちらの一覧にも入れない（F-2.12）。
    ///   - screens: 有効なディスプレイの範囲。全画面の重ねウィンドウの判定に使う（D-33）。
    static func parse(_ entries: NSArray, ownPID: ProcessID, screens: [GlobalRect]) -> WindowListSnapshot {
        var traversalTargets: [WindowInfo] = []
        var occlusionWindows: [WindowInfo] = []
        var ignoredOverlayCount = 0
        var diagnostics: [CollectionDiagnostic] = []

        for (index, element) in entries.enumerated() {
            // zIndex は CGWindowList の並び順の位置をそのまま使う。スキップした項目の分だけ番号が飛ぶが、
            // OcclusionFilter は大小だけを見るので前後関係は変わらない。
            let entry: ParsedEntry
            switch parseEntry(element, zIndex: index) {
            case .success(let parsed):
                entry = parsed
            case .failure(let failure):
                diagnostics.append(.windowListEntrySkipped(reason: "項目 \(index): \(failure.description)"))
                continue
            }

            guard entry.window.ownerPID != ownPID, entry.alpha > 0 else { continue }
            guard
                entry.ownerName != Self.screenCaptureOwnerName,
                !OcclusionFilter.isFullScreenOverlay(entry.window, screens: screens)
            else {
                ignoredOverlayCount += 1
                continue
            }
            occlusionWindows.append(entry.window)
            if entry.window.layer == 0 {
                traversalTargets.append(entry.window)
            }
        }

        return WindowListSnapshot(
            traversalTargets: traversalTargets,
            occlusionWindows: occlusionWindows,
            ignoredOverlayCount: ignoredOverlayCount,
            diagnostics: diagnostics
        )
    }

    /// ⌘⇧5 の収録を担うコマンドのプロセス名。レイヤー 0 にも画面大のウィンドウを置くので、大きさでは見分けられない（D-33）。
    private static let screenCaptureOwnerName = "screencapture"

    private struct ParsedEntry {
        let window: WindowInfo
        /// `kCGWindowAlpha`。`WindowInfo` には持たせず、分類にだけ使う。
        let alpha: Double
        /// `kCGWindowOwnerName`。API の仕様で省略されることがあるので、ないときは nil のまま扱う。
        let ownerName: String?
    }

    private enum EntryFailure: Error, CustomStringConvertible {
        case notDictionary
        case missingKey(String)
        case typeMismatch(String)
        case invalidBounds

        var description: String {
            switch self {
            case .notDictionary: "辞書ではない"
            case .missingKey(let key): "\(key) がない"
            case .typeMismatch(let key): "\(key) の型が違う"
            case .invalidBounds: "\(kCGWindowBounds as String) を矩形にできない"
            }
        }
    }

    private static func parseEntry(_ element: Any, zIndex: Int) -> Result<ParsedEntry, EntryFailure> {
        guard let dictionary = element as? NSDictionary else { return .failure(.notDictionary) }
        do {
            let number: UInt32 = try value(dictionary, kCGWindowNumber)
            let ownerPID: Int32 = try value(dictionary, kCGWindowOwnerPID)
            let layer: Int = try value(dictionary, kCGWindowLayer)
            let alpha: Double = try value(dictionary, kCGWindowAlpha)
            let boundsDictionary: NSDictionary = try value(dictionary, kCGWindowBounds)
            guard let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                return .failure(.invalidBounds)
            }
            let window = WindowInfo(
                id: WindowID(rawValue: number),
                ownerPID: ProcessID(rawValue: ownerPID),
                // CGWindowList の bounds は AX と同じグローバル座標（主ディスプレイの左上原点）なので変換しない（design.md 9.1）。
                frame: GlobalRect(rect: bounds),
                layer: layer,
                zIndex: zIndex
            )
            let ownerName = dictionary.object(forKey: kCGWindowOwnerName) as? String
            return .success(ParsedEntry(window: window, alpha: alpha, ownerName: ownerName))
        } catch {
            return .failure(error)
        }
    }

    /// 辞書の値を条件付きキャストで読む。数値は NSNumber の橋渡し（SE-0170）により、
    /// その型で正確に表せないとき（範囲外・小数）もキャストに失敗し、型の不一致として扱われる。
    private static func value<Value>(_ dictionary: NSDictionary, _ key: CFString) throws(EntryFailure) -> Value {
        guard let raw = dictionary.object(forKey: key) else { throw .missingKey(key as String) }
        guard let typed = raw as? Value else { throw .typeMismatch(key as String) }
        return typed
    }
}
