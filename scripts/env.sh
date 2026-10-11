#!/bin/bash

# 取自 BASH_SOURCE；但交互式 zsh 里 `source scripts/env.sh` 时 BASH_SOURCE 为空，
# 会静默把 ROOT 算到仓库外一层。zsh 的 source 会把 $0 设为被 source 的文件，故回退到 $0。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export ROOT

load_env_file() {
  local file="$1" line key value current
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    eval "current=\${$key:-}"
    [ -n "$current" ] && continue
    export "$key=$value"
  done < "$file"
}

load_env_file "$ROOT/.env"

RUST_ROOT="${DROIDBERTH_RUST_ROOT:-$HOME/.workbuddy-ai/binaries/rust}"
if [ -d "$RUST_ROOT/cargo/bin" ]; then
  export RUSTUP_HOME="$RUST_ROOT/rustup"
  export CARGO_HOME="$RUST_ROOT/cargo"
  case ":$PATH:" in
    *":$RUST_ROOT/cargo/bin:"*) ;;
    *) export PATH="$RUST_ROOT/cargo/bin:$PATH" ;;
  esac
fi

# 架构范围：v1 只发 Apple Silicon（PRD §5.1 已决策放弃 Intel）。
# 因此不再产出 x86_64 / universal 变体，也没有对应的 TARGET_* 变量。
export TARGET_ARM="aarch64-apple-darwin"

export SIDECAR_NAME="droidberth-adb"
export APP_NAME="DroidBerth"

# Swift 原生路线的产物位置：xcodegen 生成工程，xcodebuild 用固定 derivedDataPath。
export SWIFT_DIR="$ROOT/macos"
export CONFIGURATION="${CONFIGURATION:-Release}"

detect_bundle_dir() {
  local derived_data="${DROIDBERTH_DERIVED_DATA:-$SWIFT_DIR/build/dd}"
  printf '%s' "$derived_data/Build/Products/$CONFIGURATION"
}

export_bundle_paths() {
  export BUNDLE_DIR="$(detect_bundle_dir)"
  export APP_PATH="$BUNDLE_DIR/$APP_NAME.app"
  export DMG_DIR="$SWIFT_DIR/build/dmg"
}

export_bundle_paths

detect_identity() {
  if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
    printf '%s' "$APPLE_SIGNING_IDENTITY"
    return 0
  fi
  local found
  found="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  found="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  printf '%s' "-"
}

identity_kind() {
  case "$1" in
    "Developer ID Application"*) printf '%s' "developer-id" ;;
    "Apple Distribution"*|"Mac Installer Distribution"*) printf '%s' "apple-distribution" ;;
    "Apple Development"*|"Mac Developer"*) printf '%s' "apple-development" ;;
    "-") printf '%s' "adhoc" ;;
    *) printf '%s' "unknown" ;;
  esac
}

# MAS 版用的签名身份：优先 `Apple Distribution`。
#
# ⚠️ 那两行 `sed` 是**刻意写死的**，不要图省事改成复用 `detect_identity()`：
#    `detect_identity()` 排第一的是 **Developer ID**，而 Developer ID 签出来的包
#    能公证、能侧载、本机跑得起来 —— 唯独**上不了 App Store**。
#    差别要到「提交之后」才暴露，所以这里宁可返回 `-`（ad-hoc）让调用方一眼看出
#    这不是个能上架的包，也不要静默给出一个「看起来更好」的错身份。
#
# 返回 `-` 时调用方应当明确告知：这样签出来的包**只能本机自测**。
detect_mas_identity() {
  if [ -n "${APPLE_MAS_SIGNING_IDENTITY:-}" ]; then
    printf '%s' "$APPLE_MAS_SIGNING_IDENTITY"
    return 0
  fi
  local found
  found="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Distribution: [^"]*\)".*/\1/p' | head -1)"
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  printf '%s' "-"
}

make_signed_dmg() {
  local app="$1" out="$2" identity staging
  identity="$(detect_identity)"
  rm -f "$out"

  # DMG 里只放 .app 的话，用户得自己把图标拖到 /Applications —— 而「拖到左边那个
  # 文件夹」正是 macOS 分发的既定约定。往里放一条 /Applications 的**符号链接**
  # （不是副本），Finder 会把它画成「应用程序」，一次拖拽就装好。
  #
  # 用 ditto 而不是 cp -R 拷进去：cp -R **不保留扩展属性**，实测那样得到的副本
  # `spctl` 会判 `rejected / Insufficient Context`（这也是 Apple 建议 ditto 的原因）。
  staging="$(mktemp -d)"
  ditto "$app" "$staging/$(basename "$app")"
  ln -s /Applications "$staging/Applications"

  hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDZO "$out" >/dev/null
  rm -rf "$staging"

  codesign --force --sign "$identity" --timestamp "$out"
}

require_rust() {
  if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo not found. Set DROIDBERTH_RUST_ROOT or install rustup." >&2
    exit 1
  fi
}

require_developer_id() {
  local identity kind
  identity="$(detect_identity)"
  kind="$(identity_kind "$identity")"
  if [ "$kind" != "developer-id" ]; then
    echo "Notarization requires a 'Developer ID Application' certificate." >&2
    echo "  detected: $identity  ($kind)" >&2
    echo "  Apple Development certificates can sign and run locally but notarytool rejects them." >&2
    return 1
  fi
  return 0
}
