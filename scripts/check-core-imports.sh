#!/usr/bin/env bash
# TobiCore が OS に依存しないことを検査する（requirements.md N-6.1、design.md D-28）。
#
#   scripts/check-core-imports.sh          Packages/TobiCore/Sources を検査する
#   scripts/check-core-imports.sh <DIR>    指定したディレクトリの *.swift を検査する（スクリプト自体の確認用）
#
# 次のどちらかが見つかったら、ファイル名・行番号・理由を表示して 1 で終了する。
#   - 許可していないモジュールの import（FORBIDDEN_MODULES は理由付きで拒否、ALLOWED_MODULES 以外も拒否）
#   - OS に依存する API の名前（FORBIDDEN_APIS）
# 検査対象の *.swift が 1 つもない場合は、パスの誤りとみなして 2 で終了する（何も検査せずに通さないため）。
#
# 検査から除くもの:
#   - `//`・`///` のコメント（行全体・行末の両方）と `/* */`・`/** */` のブロックコメント（入れ子と複数行を含む）。
#     doc コメントには `CGEvent`・`NSScreen`・`AXUIElement` などの名前が説明として多く出てくるため
#     （tasks.md の T30 への申し送り）。ブロックコメントも中身は説明文で、コードとして使われることはないので除く。
#   - 文字列リテラルの中身（`"..."`・`"""..."""`・`#"..."#`）。文字列は OS の API を呼ばないため。
#     TobiCore には AX のロール名を文字列で持つ箇所がある（Traversal/TreeWalker.swift の "AXValueIndicator" など）。
#     これは比較に使うだけのデータで、ApplicationServices に依存しない。
#     ただし文字列補間 `\( ... )` の中はコードなので検査する。
#     文字列からクラスを動的に引く抜け道は、`NSClassFromString`・`dlsym` などを FORBIDDEN_APIS に入れて塞ぐ。
# 字句の扱いは簡易版（Swift の完全な字句解析ではない）。正規表現リテラルと、生文字列の中の補間は特別扱いしない。

set -euo pipefail

# --- 検査の一覧 -----------------------------------------------------------------
# 書式は "名前|理由"。理由はそのまま違反の表示に使う。

# 理由を付けて拒否するモジュール（ALLOWED_MODULES に無いものはすべて拒否するが、代表的なものは理由を明示する）
FORBIDDEN_MODULES=(
    "AppKit|UI（NSPanel・NSScreen など）は App 側の責務"
    "Cocoa|AppKit を含むため"
    "SwiftUI|UI は App 側の責務"
    "ApplicationServices|AX API（AXUIElement）と CGEvent を含む。AX の読み取りは App 側の AXClient の責務"
    "Carbon|入力ソース（TIS）・UCKeyTranslate は App 側の KeyTranslator の責務"
    "ServiceManagement|ログイン項目（SMAppService）は App 側の責務"
    "IOKit|ハードウェア・HID への依存"
)

# 許可するモジュール。CoreGraphics は幾何の計算（CGRect の contains / intersects、CG 型の Equatable）のためだけに許可する（D-28）
ALLOWED_MODULES=(
    "Foundation"
    "CoreGraphics"
    "Synchronization"
)

# OS に依存する API の名前。識別子の先頭が一致したら違反にする（例: CGEvent は CGEventTap・CGEventFlags にも一致する）
FORBIDDEN_APIS=(
    "CGEvent|イベントの生成・タップは OS に依存する（App の EventTapController・MouseClickPoster の責務）"
    "CGWindowList|ウィンドウ一覧は OS に依存する（App の WindowListSnapshot の責務）"
    "CGDisplay|ディスプレイの情報は OS に依存する（App の ScreenGeometryProvider の責務）"
    "CGMainDisplayID|ディスプレイの情報は OS に依存する（App の ScreenGeometryProvider の責務）"
    "CGGetActiveDisplayList|ディスプレイの列挙は OS に依存する"
    "CGGetOnlineDisplayList|ディスプレイの列挙は OS に依存する"
    "CGGetDisplaysWith|ディスプレイの列挙は OS に依存する"
    "CGWarpMouseCursorPosition|カーソルの移動は OS に依存する"
    "CGAssociateMouseAndMouseCursorPosition|カーソルの制御は OS に依存する"
    "CGPreflight|権限の確認は OS に依存する（App の PermissionMonitor の責務）"
    "CGRequest|権限の要求は OS に依存する（App の PermissionMonitor の責務）"
    "CGSession|ログインセッションの情報は OS に依存する"
    "AXUIElement|AX API（ApplicationServices）。TobiCore は AccessibilityTreeSource などの protocol 越しに扱う"
    "AXObserver|AX API（ApplicationServices）"
    "AXValue|AX API（ApplicationServices）。AXValue のデコードは App の AXValueDecoder の責務"
    "AXIsProcessTrusted|アクセシビリティ権限の確認は OS に依存する"
    "AXMakeProcessTrusted|アクセシビリティ権限の要求は OS に依存する"
    "kAX|AX API の定数（ApplicationServices）。ロール名などは文字列で持つ"
    "NSScreen|画面の情報は AppKit（App の ScreenGeometryProvider の責務）"
    "NSSound|効果音は AppKit（App の FeedbackPlayer の責務）"
    "NSPanel|オーバーレイは AppKit（App の OverlayPanel の責務）"
    "NSWindow|ウィンドウは AppKit"
    "NSView|ビューは AppKit"
    "NSWorkspace|前面アプリの取得などは AppKit"
    "NSRunningApplication|アプリの情報は AppKit"
    "NSApp|アプリケーションオブジェクトは AppKit（NSApp・NSApplication）"
    "NSEvent|イベントは AppKit"
    "NSStatusBar|メニューバーの項目は AppKit"
    "NSStatusItem|メニューバーの項目は AppKit"
    "NSColor|色は AppKit。TobiCore は RGBAColor を使う"
    "NSFont|フォントは AppKit"
    "TISCopy|入力ソースは Carbon（App の KeyTranslator の責務）"
    "TISGet|入力ソースは Carbon（App の KeyTranslator の責務）"
    "UCKeyTranslate|キーの変換は Carbon（App の KeyTranslator の責務）"
    "LMGetKbdType|キーボードの種類は Carbon"
    "SMAppService|ログイン項目は ServiceManagement"
    "IOHID|HID は IOKit"
    "NSClassFromString|文字列からクラスを引くと、import を経ずに AppKit などに依存できるため"
    "dlopen|動的ロードで、import を経ずに OS の API に依存できるため"
    "dlsym|動的ロードで、import を経ずに OS の API に依存できるため"
)

# --- 準備 -----------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

usage() {
    echo "使い方: $0 [検査するディレクトリ]" >&2
}

case "$#" in
    0) TARGET_DIR="${REPO_ROOT}/Packages/TobiCore/Sources" ;;
    1)
        if [[ "$1" == "-h" || "$1" == "--help" ]]; then
            usage
            exit 0
        fi
        TARGET_DIR="$1"
        ;;
    *)
        usage
        exit 2
        ;;
esac
readonly TARGET_DIR

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "エラー: ディレクトリがありません: $TARGET_DIR" >&2
    exit 2
fi

SWIFT_FILES=()
while IFS= read -r -d '' file; do
    SWIFT_FILES+=("$file")
done < <(find "$TARGET_DIR" -type f -name '*.swift' -print0 | sort -z)

if ((${#SWIFT_FILES[@]} == 0)); then
    echo "エラー: 検査する *.swift がありません: $TARGET_DIR" >&2
    exit 2
fi

# --- コメントと文字列の除去 -----------------------------------------------------
# 各行を「ファイル名<TAB>行番号<TAB>コメントと文字列の中身を除いたコード」にして出力する。
# 文字列は区切り（"" や """"""）だけを残し、中身を消す。補間 \( ... ) の中はコードとして残す。
# 補間の中にさらに文字列がある場合に備え、文字列の状態はスタックで持つ。
strip_comments_and_strings() {
    awk '
    function reset_state() {
        depth = 0; kind = 0; hashcount = 0; ip = 0; sp = 0
    }
    function hashes(n,    s, k) {
        s = ""
        for (k = 0; k < n; k++) s = s "#"
        return s
    }
    FNR == 1 { reset_state() }
    {
        line = $0; n = length(line); i = 1; out = ""
        while (i <= n) {
            c = substr(line, i, 1); c2 = substr(line, i, 2)

            # ブロックコメントの中（Swift のブロックコメントは入れ子にできる）
            if (depth > 0) {
                if (c2 == "/*") { depth++; i += 2; continue }
                if (c2 == "*/") { depth--; i += 2; continue }
                i++; continue
            }

            # 文字列の中身（kind: 1 = 1 行、2 = 複数行。hashcount は生文字列の # の数）
            if (kind > 0 && ip == 0) {
                h = hashes(hashcount)
                if (kind == 1 && c == "\"" && substr(line, i + 1, hashcount) == h) {
                    out = out "\"" h; i += 1 + hashcount
                    kind = sk[sp]; hashcount = sh[sp]; ip = si[sp]; sp--
                    continue
                }
                if (kind == 2 && substr(line, i, 3) == "\"\"\"" && substr(line, i + 3, hashcount) == h) {
                    out = out "\"\"\"" h; i += 3 + hashcount
                    kind = sk[sp]; hashcount = sh[sp]; ip = si[sp]; sp--
                    continue
                }
                if (hashcount == 0 && c == "\\") {
                    if (substr(line, i + 1, 1) == "(") { out = out "\\("; ip = 1; i += 2; continue }
                    i += 2; continue
                }
                i++; continue
            }

            # ここからコード（文字列の外、または補間の中）
            if (c2 == "//") break
            if (c2 == "/*") { depth = 1; i += 2; continue }

            if (ip > 0) {
                if (c == "(") ip++
                else if (c == ")") {
                    ip--
                    if (ip == 0) { out = out ")"; i++; continue }
                }
            }

            # 文字列の始まり（"..."・"""..."""・#"..."#）
            j = i; nh = 0
            while (substr(line, j, 1) == "#") { nh++; j++ }
            if (substr(line, j, 1) == "\"") {
                sp++; sk[sp] = kind; sh[sp] = hashcount; si[sp] = ip
                hashcount = nh; ip = 0
                if (substr(line, j, 3) == "\"\"\"") { kind = 2; out = out hashes(nh) "\"\"\""; i = j + 3 }
                else { kind = 1; out = out hashes(nh) "\""; i = j + 1 }
                continue
            }

            out = out c; i++
        }
        # 1 行の文字列は行をまたがない。閉じていなければ（コンパイルエラーのはずだが）状態を戻す
        if (kind == 1) { kind = 0; hashcount = 0; ip = 0; sp = 0 }
        printf "%s\t%d\t%s\n", FILENAME, FNR, out
    }
    ' "$@"
}

# --- 検査 -----------------------------------------------------------------------
# import 文: 属性（@preconcurrency など）と、部分 import（import struct AppKit.NSRect など）も拾う
readonly IMPORT_PATTERN='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)'

violation_count=0
report() {
    local file="$1" lineno="$2" message="$3"
    echo "${file#"${REPO_ROOT}/"}:${lineno}: ${message}" >&2
    violation_count=$((violation_count + 1))
}

module_reason() {
    local module="$1" entry
    for entry in "${FORBIDDEN_MODULES[@]}"; do
        if [[ "${entry%%|*}" == "$module" ]]; then
            echo "${entry#*|}"
            return 0
        fi
    done
    for entry in "${ALLOWED_MODULES[@]}"; do
        if [[ "$entry" == "$module" ]]; then
            return 0
        fi
    done
    echo "許可リスト（ALLOWED_MODULES）にないモジュール。OS に依存しないことを確かめてから追加する"
}

check_line() {
    local file="$1" lineno="$2" code="$3" entry name pattern reason
    if [[ "$code" =~ $IMPORT_PATTERN ]]; then
        local module="${BASH_REMATCH[4]}"
        reason="$(module_reason "$module")"
        if [[ -n "$reason" ]]; then
            report "$file" "$lineno" "import ${module} は禁止: ${reason}"
        fi
    fi
    for entry in "${FORBIDDEN_APIS[@]}"; do
        name="${entry%%|*}"
        pattern="(^|[^A-Za-z0-9_])${name}"
        if [[ "$code" =~ $pattern ]]; then
            report "$file" "$lineno" "OS に依存する API（${name}）は禁止: ${entry#*|}"
        fi
    done
}

stripped="$(strip_comments_and_strings "${SWIFT_FILES[@]}")"
while IFS=$'\t' read -r file lineno code; do
    check_line "$file" "$lineno" "$code"
done <<<"$stripped"

if ((violation_count > 0)); then
    echo "TobiCore の依存の検査: ${violation_count} 件の違反（N-6.1、D-28）" >&2
    exit 1
fi

echo "TobiCore の依存の検査: 違反なし（${#SWIFT_FILES[@]} ファイル）"
