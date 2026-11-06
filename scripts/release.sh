#!/usr/bin/env bash
# Tobe のリリース用 zip を作る（design.md 16.2、N-7.1〜N-7.3）。
#
#   scripts/release.sh            アーカイブ → 取り出し → 署名の検証 → zip → sha256
#   scripts/release.sh --dry-run  実行するコマンドを表示するだけ（何も生成・変更しない）
#
# 自己署名証明書（design.md 16.1）で署名する。Apple Developer Program に参加していないため、
# 公証（notarytool）と `xcodebuild -exportArchive`（Apple 発行の証明書が前提）は使わない。
# 検証が 1 つでも失敗したら、理由を表示して 0 以外で終了する。

set -euo pipefail

# --- 定数 ---------------------------------------------------------------------
# スキーム名だけをここに置く。バンドル ID・バージョン・署名 ID・製品名は、
# project.yml / Config/Base.xcconfig（Config/Local.xcconfig の上書きを含む）から
# `xcodebuild -showBuildSettings` で読み取る。値を二重に持つと、設定を変えたときに
# 検証が古い値と比べてしまうため、スクリプトには書かない。
readonly SCHEME="Tobe"
readonly CONFIGURATION="Release"

# リポジトリのルートで動かす（どこから呼ばれても同じパスになるように）
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

readonly PROJECT="${SCHEME}.xcodeproj"
# 出力はすべて build/ の下（.gitignore の対象）
readonly BUILD_DIR="build"
readonly ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}.xcarchive"
readonly EXPORT_DIR="${BUILD_DIR}/export"
# Debug ビルドの DerivedData と混ざらないよう、リリース用に分ける
readonly DERIVED_DATA_PATH="${BUILD_DIR}/ReleaseDerivedData"

# --- 引数 ---------------------------------------------------------------------
DRY_RUN=false
usage() {
    echo "使い方: $0 [--dry-run]" >&2
}
while (($# > 0)); do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "エラー: 不明な引数です: $1" >&2
            usage
            exit 2
            ;;
    esac
    shift
done
readonly DRY_RUN

# --- 共通処理 -----------------------------------------------------------------
fail() {
    echo "エラー: $*" >&2
    exit 1
}

step() {
    echo
    echo "==> $*"
}

# コマンドを表示し、--dry-run でなければ実行する
run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == false ]]; then
        "$@"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 が見つかりません。$2"
}

# --- 0. 前提の確認 ------------------------------------------------------------
step "前提の確認"
require_command xcodegen "brew install xcodegen でインストールしてください。"
require_command xcodebuild "Xcode をインストールしてください。"
require_command codesign "Xcode の Command Line Tools をインストールしてください。"
require_command security "macOS 標準のコマンドです。"
require_command plutil "macOS 標準のコマンドです。"
require_command ditto "macOS 標準のコマンドです。"
require_command shasum "macOS 標準のコマンドです。"
echo "必要なコマンドがそろっています"

# --- 1. プロジェクトの生成と設定値の読み取り ----------------------------------
step "プロジェクトの生成"
run xcodegen generate

step "Release の設定値の読み取り（xcodebuild -showBuildSettings）"
SHOW_SETTINGS_CMD=(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings -json)
if [[ "$DRY_RUN" == true ]]; then
    printf '+'
    printf ' %q' "${SHOW_SETTINGS_CMD[@]}"
    printf '\n'
    # dry-run では生成も読み取りもしないため、値の代わりに設定名を表示する
    BUNDLE_ID="<PRODUCT_BUNDLE_IDENTIFIER>"
    VERSION="<MARKETING_VERSION>"
    SIGN_IDENTITY="<CODE_SIGN_IDENTITY>"
    APP_NAME="<FULL_PRODUCT_NAME>"
else
    SETTINGS_JSON="$("${SHOW_SETTINGS_CMD[@]}" 2>/dev/null)" ||
        fail "xcodebuild -showBuildSettings に失敗しました（スキーム ${SCHEME}、構成 ${CONFIGURATION}）"

    build_setting() {
        local value
        value="$(plutil -extract "0.buildSettings.$1" raw -o - - <<<"$SETTINGS_JSON")" ||
            fail "ビルド設定 $1 を読み取れませんでした"
        [[ -n "$value" ]] || fail "ビルド設定 $1 が空です"
        printf '%s' "$value"
    }

    BUNDLE_ID="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"
    VERSION="$(build_setting MARKETING_VERSION)"
    SIGN_IDENTITY="$(build_setting CODE_SIGN_IDENTITY)"
    APP_NAME="$(build_setting FULL_PRODUCT_NAME)"
fi
readonly BUNDLE_ID VERSION SIGN_IDENTITY APP_NAME
echo "バンドル ID: ${BUNDLE_ID}"
echo "バージョン : ${VERSION}"
echo "署名 ID    : ${SIGN_IDENTITY}"
echo "製品       : ${APP_NAME}"

readonly ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}"
readonly APP_PATH="${EXPORT_DIR}/${APP_NAME}"
readonly ZIP_PATH="${BUILD_DIR}/${SCHEME}-${VERSION}.zip"

# --- 2. 署名証明書の確認 ------------------------------------------------------
# 指定要件の `certificate leaf = H"…"` と比べるため、証明書の SHA-1 を先に求める。
# 同じ名前の証明書が複数あると、どれで署名されたか分からず、更新時に許可が外れうるので止める。
step "署名証明書の確認（${SIGN_IDENTITY}）"
FIND_CERT_CMD=(security find-certificate -a -c "$SIGN_IDENTITY" -Z)
if [[ "$DRY_RUN" == true ]]; then
    printf '+'
    printf ' %q' "${FIND_CERT_CMD[@]}"
    printf '\n'
    CERT_SHA1="<証明書の SHA-1>"
else
    CERT_OUTPUT="$("${FIND_CERT_CMD[@]}" 2>/dev/null)" ||
        fail "キーチェーンに証明書「${SIGN_IDENTITY}」がありません（design.md 16.1 の手順で作成してください）"
    CERT_SHA1_LIST="$(sed -n 's/^SHA-1 hash: //p' <<<"$CERT_OUTPUT")"
    CERT_COUNT="$(grep -c . <<<"$CERT_SHA1_LIST" || true)"
    [[ "$CERT_COUNT" -eq 1 ]] ||
        fail "証明書「${SIGN_IDENTITY}」が ${CERT_COUNT} 件見つかりました。1 件だけにしてください"
    # codesign の指定要件は小文字の 16 進で表示される
    CERT_SHA1="$(tr '[:upper:]' '[:lower:]' <<<"$CERT_SHA1_LIST")"
fi
readonly CERT_SHA1
echo "証明書の SHA-1: ${CERT_SHA1}"

# --- 3. アーカイブ ------------------------------------------------------------
step "アーカイブ（${CONFIGURATION}）"
# 前回の成果物が残っていると、古いファイルが混ざったまま検証に通りうるので消してから作る
run rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$ZIP_PATH"
run xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" -archivePath "$ARCHIVE_PATH" archive

# --- 4. 取り出し --------------------------------------------------------------
step "xcarchive から ${APP_NAME} を取り出す"
if [[ "$DRY_RUN" == false && ! -d "$ARCHIVED_APP" ]]; then
    fail "アーカイブに ${ARCHIVED_APP} がありません"
fi
run mkdir -p "$EXPORT_DIR"
# ditto はシンボリックリンク・拡張属性・署名を保ったままコピーする
run ditto "$ARCHIVED_APP" "$APP_PATH"

# --- 5. 検証 ------------------------------------------------------------------
step "署名の検証"

# codesign -d 系は結果を標準エラーに出すため、2>&1 でまとめて受け取る。
# $(…) の中で呼ぶので、表示するコマンドは標準エラーに出して画面に残す
capture() {
    {
        printf '+'
        printf ' %q' "$@"
        printf '\n'
    } >&2
    if [[ "$DRY_RUN" == false ]]; then
        "$@" 2>&1
    fi
}

# (1) 署名が壊れていない（N-7.1）
run codesign --verify --deep --strict --verbose=2 "$APP_PATH" ||
    fail "codesign --verify に失敗しました"

# (2) 自己署名証明書で署名され、Hardened Runtime が有効（N-7.1、D-26）
# `codesign -dv`（v が 1 つ）では Authority= の行が出ないため --verbose=4 を使う
DETAILS="$(capture codesign -d --verbose=4 "$APP_PATH")" ||
    fail "codesign -d --verbose=4 に失敗しました"
if [[ "$DRY_RUN" == false ]]; then
    grep -qxF "Identifier=${BUNDLE_ID}" <<<"$DETAILS" ||
        fail "署名の Identifier が ${BUNDLE_ID} ではありません"
    grep -qxF "Authority=${SIGN_IDENTITY}" <<<"$DETAILS" ||
        fail "Authority=${SIGN_IDENTITY} がありません（別の証明書か ad-hoc で署名されています）"
    grep -qE '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<<"$DETAILS" ||
        fail "Hardened Runtime（flags の runtime）が有効になっていません"
    echo "OK: Identifier=${BUNDLE_ID}、Authority=${SIGN_IDENTITY}、runtime"
fi

# (3) 指定要件が証明書に結び付いている（N-7.2: 更新してもアクセシビリティの許可が外れない）
# 自己署名証明書では `certificate root` ではなく `certificate leaf` になる（T3 で確認済み）
REQUIREMENT="$(capture codesign -d -r- "$APP_PATH")" ||
    fail "codesign -d -r- に失敗しました"
if [[ "$DRY_RUN" == false ]]; then
    EXPECTED_REQUIREMENT="designated => identifier \"${BUNDLE_ID}\" and certificate leaf = H\"${CERT_SHA1}\""
    grep -qxF "$EXPECTED_REQUIREMENT" <<<"$REQUIREMENT" ||
        fail "指定要件が想定と違います。想定: ${EXPECTED_REQUIREMENT}"
    echo "OK: ${EXPECTED_REQUIREMENT}"
fi

# (4) Sandbox なし（C-1、D-25）。Release には get-task-allow（デバッガの接続許可）も付けない
ENTITLEMENTS="$(capture codesign -d --entitlements - --xml "$APP_PATH")" ||
    fail "codesign -d --entitlements に失敗しました"
if [[ "$DRY_RUN" == false ]]; then
    for forbidden in com.apple.security.app-sandbox com.apple.security.get-task-allow; do
        if grep -qF "$forbidden" <<<"$ENTITLEMENTS"; then
            fail "entitlement ${forbidden} が含まれています"
        fi
    done
    echo "OK: app-sandbox、get-task-allow の entitlement なし"
fi

# (5) Info.plist の値が設定と一致する（取り出したものが目的のビルドであることの確認）
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
if [[ "$DRY_RUN" == true ]]; then
    capture plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST"
    capture plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST"
else
    PLIST_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")" ||
        fail "Info.plist の CFBundleIdentifier を読み取れません"
    PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")" ||
        fail "Info.plist の CFBundleShortVersionString を読み取れません"
    [[ "$PLIST_BUNDLE_ID" == "$BUNDLE_ID" ]] ||
        fail "Info.plist の CFBundleIdentifier（${PLIST_BUNDLE_ID}）が ${BUNDLE_ID} ではありません"
    [[ "$PLIST_VERSION" == "$VERSION" ]] ||
        fail "Info.plist の CFBundleShortVersionString（${PLIST_VERSION}）が ${VERSION} ではありません"
    echo "OK: Info.plist ${PLIST_BUNDLE_ID} ${PLIST_VERSION}"
fi

# --- 6. zip -------------------------------------------------------------------
step "zip に固める"
# Finder の「圧縮」と同じ形式。--keepParent で zip の直下に ${APP_NAME} を置く
run ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

step "完了"
if [[ "$DRY_RUN" == true ]]; then
    run shasum -a 256 "$ZIP_PATH"
    echo "（--dry-run のため何も実行していません）"
else
    echo "zip: ${REPO_ROOT}/${ZIP_PATH}"
    shasum -a 256 "$ZIP_PATH"
fi
