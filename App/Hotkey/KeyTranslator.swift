import AppKit
import Carbon
import TobiCore
import os

/// keyCode をキーボードレイアウトに従って文字に変換し、`HintKeyInput` に分類する（design.md 7.6、D-7、F-4.8）。
///
/// - 変換には `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()` の ASCII 対応のレイアウトを使う。
///   日本語入力（ローマ字）がオンでも下地の US / JIS / ABC などのレイアウトで変換するので、同じキーが同じ文字になる。
///   Dvorak などのレイアウトを選んだときは、そのレイアウトに従う。
/// - 修飾キーなしで変換する（Shift の有無を無視する。F-4.5）。⌘ / ⌃ / ⌥ の判定は `HintKeyInput.classify` が行う。
/// - Esc と Backspace はレイアウトに依存させず、`classify` が keyCode で判定する。
///
/// スレッド: MainActor でだけ使う。TIS（Text Input Sources）の API はメインスレッドで呼ぶ必要があり、
/// 入力ソースの変更通知もメインスレッドで受けるため（design.md 7.6、13）。
/// イベントタップのスレッドでは変換せず、keyCode・修飾キー・リピートの有無だけを `TapEvent` で MainActor に送る。
///
/// `DistributedNotificationCenter` のセレクタ方式の登録（`suspensionBehavior` を指定できるのはこれだけ）のため
/// `NSObject` を継承する。
@MainActor
final class KeyTranslator: NSObject {
    private let logger = Logger(subsystem: "io.github.hatohato25.tobi", category: "hotkey")
    /// 変換に使うレイアウト。入力ソースの変更通知を受けたら作り直す。
    private var layoutState: LayoutState

    private enum LayoutState {
        case loaded(KeyboardLayout)
        case failed(KeyTranslationError)
    }

    override init() {
        layoutState = Self.loadLayoutState()
        super.init()
        logLayoutState(reason: "初期化")
        // Tobi はアクティブにならない（LSUIElement、フォーカスを奪わないオーバーレイ）。
        // 既定の suspensionBehavior（coalesce）では、非アクティブの間は分散通知の配送が保留されるため、
        // 入力ソースを変えてもキャッシュが古いままになる。deliverImmediately で常に受け取る。
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(selectedInputSourceDidChange(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    isolated deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// keyDown を `HintKeyInput` に分類する。
    ///
    /// レイアウトが読めない・変換に失敗したときは、エラーをログに出したうえで「変換できない」として
    /// `classify` に渡す（`.ignored(.untranslatable)` になる）。Esc と Backspace は keyCode で判定されるので、
    /// この場合でもヒントモードを抜けられる。
    ///
    /// - Parameters:
    ///   - keyCode: 仮想キーコード（`CGEvent` の `keyboardEventKeycode`）。
    ///   - flags: keyDown の時点の修飾キー（`CGEventFlags` の生の値）。
    ///   - isRepeat: キーリピートによる keyDown か（`keyboardEventAutorepeat != 0`）。
    func hintKeyInput(keyCode: UInt16, flags: ModifierFlags, isRepeat: Bool) -> HintKeyInput {
        let translated: Character?
        do {
            translated = try character(forKeyCode: keyCode)
        } catch {
            // 押したキー（keyCode）はキー入力の内容なのでログに出さない。エラーの種類だけを残す。
            logger.error("キーを文字に変換できませんでした: \(String(describing: error), privacy: .public)")
            translated = nil
        }
        return HintKeyInput.classify(keyCode: keyCode, translated: translated, flags: flags, isRepeat: isRepeat)
    }

    /// keyCode を、現在の ASCII 対応のレイアウトで修飾キーなしに変換した文字を返す。
    ///
    /// - Returns: 1 文字の印字可能な文字。キーが文字を出さない（矢印、F キー、JIS の「英数」「かな」など）なら `nil`。
    /// - Throws: レイアウトが取れない、または `UCKeyTranslate` が失敗した。
    func character(forKeyCode keyCode: UInt16) throws(KeyTranslationError) -> Character? {
        if case .failed = layoutState {
            // 起動直後などに一時的に取れなかった場合に備えて、使うときに取り直す。
            layoutState = Self.loadLayoutState()
            logLayoutState(reason: "再試行")
        }
        switch layoutState {
        case .loaded(let layout):
            return try layout.character(forKeyCode: keyCode)
        case .failed(let error):
            throw error
        }
    }

    /// 現在のレイアウトの入力ソース ID（例: `com.apple.keylayout.US`）。手動確認とログのため。
    var currentLayoutID: String? {
        switch layoutState {
        case .loaded(let layout): layout.inputSourceID
        case .failed: nil
        }
    }

    @objc private func selectedInputSourceDidChange(_ notification: Notification) {
        // 選んだ入力ソースが日本語入力でも、下地の ASCII 対応のレイアウトが変わっていることがあるので毎回作り直す。
        layoutState = Self.loadLayoutState()
        logLayoutState(reason: "入力ソースの変更")
    }

    private func logLayoutState(reason: String) {
        switch layoutState {
        case .loaded(let layout):
            logger.info(
                """
                キーボードレイアウトを読み込みました（\(reason, privacy: .public)）: \
                \(layout.inputSourceID, privacy: .public)
                """
            )
        case .failed(let error):
            logger.error(
                """
                キーボードレイアウトを読み込めませんでした（\(reason, privacy: .public)）: \
                \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private static func loadLayoutState() -> LayoutState {
        do {
            return .loaded(try KeyboardLayout.currentASCIICapable())
        } catch {
            return .failed(error)
        }
    }
}

/// `KeyTranslator` の失敗。
enum KeyTranslationError: Error, CustomStringConvertible {
    /// `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()` が入力ソースを返さなかった。
    case inputSourceUnavailable
    /// 入力ソースに `kTISPropertyUnicodeKeyLayoutData`（'uchr' のデータ）がない、または CFData ではない。
    case layoutDataUnavailable(inputSourceID: String)
    /// `UCKeyTranslate` が `noErr` 以外を返した。
    case translateFailed(status: OSStatus)

    var description: String {
        switch self {
        case .inputSourceUnavailable:
            "ASCII 対応の入力ソースを取得できません"
        case .layoutDataUnavailable(let inputSourceID):
            "入力ソース \(inputSourceID) にキーレイアウトのデータがありません"
        case .translateFailed(let status):
            "UCKeyTranslate が失敗しました（OSStatus \(status)）"
        }
    }
}

/// 読み込んだキーボードレイアウト（'uchr' のデータのコピー）。
///
/// データを `Data` にコピーして持つので、TIS の入力ソースの寿命とは無関係に使える。
/// 変換（`character(forKeyCode:)`）は自分の値だけを読む純粋な処理。
private struct KeyboardLayout {
    let inputSourceID: String
    let layoutData: Data
    /// `UCKeyTranslate` に渡すキーボードの種類。`LMGetKbdType()` を読み込み時に MainActor で取っておく。
    let keyboardType: UInt32

    /// UCKeyTranslate が 1 回のキーで返す UTF-16 の最大長。通常は 1。合字を出すレイアウトのために余裕を持たせる。
    private static let maxStringLength = 4

    static func currentASCIICapable() throws(KeyTranslationError) -> KeyboardLayout {
        // Copy 規則なので、返された参照の所有権を受け取る（takeRetainedValue）。
        guard let unmanagedSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource() else {
            throw .inputSourceUnavailable
        }
        let source = unmanagedSource.takeRetainedValue()
        let inputSourceID = stringProperty(of: source, key: kTISPropertyInputSourceID) ?? "(ID なし)"

        // Get 規則なので所有権は受け取らない（takeUnretainedValue）。source が生きている間にコピーする。
        guard let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw .layoutDataUnavailable(inputSourceID: inputSourceID)
        }
        let value = Unmanaged<CFTypeRef>.fromOpaque(rawData).takeUnretainedValue()
        guard CFGetTypeID(value) == CFDataGetTypeID() else {
            throw .layoutDataUnavailable(inputSourceID: inputSourceID)
        }
        // CFGetTypeID で CFData であることを確認済み（CF 型は条件付きキャストできないため unsafeDowncast を使う）。
        let cfData = unsafeDowncast(value, to: CFData.self)
        let layoutData = Data(cfData as Data)

        return KeyboardLayout(
            inputSourceID: inputSourceID,
            layoutData: layoutData,
            keyboardType: UInt32(LMGetKbdType())
        )
    }

    func character(forKeyCode keyCode: UInt16) throws(KeyTranslationError) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: Self.maxStringLength)
        let keyboardType = keyboardType
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode,
                UInt16(kUCKeyActionDown),
                0,  // 修飾キーなし（Shift を無視する。F-4.5）
                keyboardType,
                // デッドキー（´ など）で状態を持ち越さず、そのキー自体の文字を返させる。
                // 返った文字は英字ではないので、classify で .nonLetterCharacter になる。
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                Self.maxStringLength,
                &length,
                &buffer
            )
        }
        guard status == noErr else {
            throw .translateFailed(status: status)
        }
        guard length > 0 else {
            return nil
        }
        let string = String(decoding: buffer.prefix(length), as: UTF16.self)
        guard string.count == 1, let character = string.first, Self.isPrintable(character) else {
            return nil
        }
        return character
    }

    /// 制御文字（Return、Tab、矢印キーの 0x1C〜0x1F、F キーの 0x10 など）と私用領域（0xF700〜 の機能キー）を
    /// 「文字に変換できない」として扱うための判定。design.md 7.6 で矢印キーや F キーを `.untranslatable` にしているため。
    private static func isPrintable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            !scalar.properties.generalCategory.isControlOrPrivateUse
        }
    }

    private static func stringProperty(of source: TISInputSource, key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        // CFGetTypeID で CFString であることを確認済み。
        return unsafeDowncast(value, to: CFString.self) as String
    }
}

extension Unicode.GeneralCategory {
    fileprivate var isControlOrPrivateUse: Bool {
        switch self {
        case .control, .privateUse, .format, .surrogate, .unassigned:
            true
        default:
            false
        }
    }
}
