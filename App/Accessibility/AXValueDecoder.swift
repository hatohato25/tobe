import ApplicationServices
import TobiCore

/// `AXValueDecoder` が変換する先の型。型の不一致を報告するときに、期待した型を示す。
enum AXValueKind: String, Hashable, Sendable {
    case string
    case bool
    case point
    case size
    case elements
    case strings
}

/// AX の属性値を型付きの値にできなかった理由。
///
/// design.md 8.3 では、どちらも「属性なし」として扱い、件数を診断に記録する（扱いを決めるのは呼び出し側。T41）。
/// ここでは区別して返し、黙って既定値にしない。
enum AXValueDecodingError: Error, Hashable, Sendable, CustomStringConvertible {
    /// `AXUIElementCopyMultipleAttributeValues` で、その属性の位置に `AXValue`（`kAXValueAXErrorType`）が入っていた。
    /// その属性だけが読めなかったことを表す（`.attributeUnsupported` / `.noValue` は `.attributeUnsupported` になる）。
    case attributeError(AccessibilityReadError)
    /// 値の型が期待と違った。`actualTypeID` は診断用（`CFCopyTypeIDDescription` で型名にできる）。
    /// 配列のときは、型の合わなかった最初の要素の型 ID（配列でない値なら、その値の型 ID）。
    case typeMismatch(expected: AXValueKind, actualTypeID: CFTypeID)
    /// `AXAttributeValues` から、一括取得で要求していない属性を取り出そうとした（呼び出し側の誤り）。
    case notRequested(attribute: String)

    var description: String {
        switch self {
        case .attributeError(let error):
            "attributeError(\(error))"
        case .typeMismatch(let expected, let actualTypeID):
            "typeMismatch(expected: \(expected.rawValue), actual: \(CFCopyTypeIDDescription(actualTypeID) as String))"
        case .notRequested(let attribute):
            "notRequested(\(attribute))"
        }
    }
}

/// `CFTypeRef` を Swift の型付きの値に変換する（design.md 8.3）。
///
/// `as!` を使わないため、`CFGetTypeID`（と `AXValue` なら `AXValueGetType`）で型を確かめてから
/// `unsafeDowncast` する。型 ID が一致していれば、その CF 型のオブジェクトであることが保証される
/// （CF 型は Swift の条件付きキャスト `as?` が常に成功してしまい、型の確認に使えない）。
///
/// 一括取得の結果に入る「その属性の失敗」（`kAXValueAXErrorType` の `AXValue`）は、どの変換でも
/// `.attributeError` として報告する（型の不一致と区別するため）。
enum AXValueDecoder {
    /// `CFString` → `String`（`AXRole`、`AXSubrole` など）。
    static func string(_ value: CFTypeRef) throws(AXValueDecodingError) -> String {
        let typeID = CFGetTypeID(value)
        guard typeID == CFStringGetTypeID() else {
            throw mismatch(value, expected: .string)
        }
        return unsafeDowncast(value, to: CFString.self) as String
    }

    /// `CFBoolean` → `Bool`（`AXEnabled` など）。`CFNumber` の 0 / 1 は受け付けない（型が違う）。
    static func bool(_ value: CFTypeRef) throws(AXValueDecodingError) -> Bool {
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw mismatch(value, expected: .bool)
        }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    /// `AXValue`（`kAXValueCGPointType`）→ `CGPoint`（`AXPosition`。左上原点のグローバル座標）。
    static func point(_ value: CFTypeRef) throws(AXValueDecodingError) -> CGPoint {
        let boxed = try axValue(value, type: .cgPoint, expected: .point)
        var point = CGPoint.zero
        guard AXValueGetValue(boxed, .cgPoint, &point) else {
            throw .typeMismatch(expected: .point, actualTypeID: CFGetTypeID(value))
        }
        return point
    }

    /// `AXValue`（`kAXValueCGSizeType`）→ `CGSize`（`AXSize`）。
    static func size(_ value: CFTypeRef) throws(AXValueDecodingError) -> CGSize {
        let boxed = try axValue(value, type: .cgSize, expected: .size)
        var size = CGSize.zero
        guard AXValueGetValue(boxed, .cgSize, &size) else {
            throw .typeMismatch(expected: .size, actualTypeID: CFGetTypeID(value))
        }
        return size
    }

    /// `AXUIElement` の `CFArray` → `[AXElementRef]`（`AXChildren`、`AXVisibleRows`、`AXWindows` など）。
    /// 空の配列は `[]`。1 つでも `AXUIElement` でない要素があれば、全体を型の不一致にする。
    static func elements(_ value: CFTypeRef) throws(AXValueDecodingError) -> [AXElementRef] {
        let items = try arrayItems(value, expected: .elements)
        let elementTypeID = AXUIElementGetTypeID()
        if let wrong = items.first(where: { CFGetTypeID($0) != elementTypeID }) {
            throw .typeMismatch(expected: .elements, actualTypeID: CFGetTypeID(wrong))
        }
        return items.map { AXElementRef(raw: unsafeDowncast($0, to: AXUIElement.self)) }
    }

    /// `CFString` の `CFArray` → `[String]`（`AXUIElementCopyActionNames` の結果など）。
    /// 1 つでも `CFString` でない要素があれば、全体を型の不一致にする。
    static func strings(_ value: CFTypeRef) throws(AXValueDecodingError) -> [String] {
        let items = try arrayItems(value, expected: .strings)
        let stringTypeID = CFStringGetTypeID()
        if let wrong = items.first(where: { CFGetTypeID($0) != stringTypeID }) {
            throw .typeMismatch(expected: .strings, actualTypeID: CFGetTypeID(wrong))
        }
        return items.map { unsafeDowncast($0, to: CFString.self) as String }
    }

    // MARK: - 内部

    /// 中身の型が `type` の `AXValue` であることを確かめて返す。違えば型の不一致（失敗の値なら `.attributeError`）。
    ///
    /// 中身の取り出し（`AXValueGetValue`）は呼び出し側が具体的な型（`CGPoint` / `CGSize`）の変数で行う。
    /// ジェネリックな `inout T` に書き込ませると、`T` が参照を含む型でも通ってしまい安全でないため。
    private static func axValue(
        _ value: CFTypeRef,
        type: AXValueType,
        expected: AXValueKind
    ) throws(AXValueDecodingError) -> AXValue {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            throw .typeMismatch(expected: expected, actualTypeID: CFGetTypeID(value))
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == type else {
            throw mismatch(value, expected: expected)
        }
        return axValue
    }

    /// `CFArray` の要素を取り出す。配列でなければ型の不一致。
    private static func arrayItems(
        _ value: CFTypeRef,
        expected: AXValueKind
    ) throws(AXValueDecodingError) -> [CFTypeRef] {
        guard CFGetTypeID(value) == CFArrayGetTypeID() else {
            throw mismatch(value, expected: expected)
        }
        let array = unsafeDowncast(value, to: CFArray.self)
        let count = CFArrayGetCount(array)
        var items: [CFTypeRef] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            // CFArray は NULL を要素に持てない（範囲内の添字なら必ず値がある）。万一 NULL なら型の不一致として扱う
            guard let raw = CFArrayGetValueAtIndex(array, index) else {
                throw .typeMismatch(expected: expected, actualTypeID: CFArrayGetTypeID())
            }
            // 配列が所有している値を借りるだけなので、retain の数は変えない（takeUnretainedValue）。
            // 取り出した値は Swift の参照として保持され、配列が解放されても生き残る（ARC が retain する）
            items.append(Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue())
        }
        return items
    }

    /// 期待した型でなかった値のエラーを作る。一括取得の「その属性の失敗」なら `.attributeError` にする。
    ///
    /// 戻り値はエラーの値で、呼び出し側が `throw mismatch(...)` で投げる。
    private static func mismatch(_ value: CFTypeRef, expected: AXValueKind) -> AXValueDecodingError {
        let typeID = CFGetTypeID(value)
        guard typeID == AXValueGetTypeID() else {
            return .typeMismatch(expected: expected, actualTypeID: typeID)
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var code = AXError.success
        guard AXValueGetType(axValue) == .axError, AXValueGetValue(axValue, .axError, &code) else {
            return .typeMismatch(expected: expected, actualTypeID: typeID)
        }
        // 失敗の位置に .success が入ることは AX の仕様上ないが、値もないので型の不一致として報告する
        guard code != .success else {
            return .typeMismatch(expected: expected, actualTypeID: typeID)
        }
        return .attributeError(AXClient.readError(for: code))
    }
}
