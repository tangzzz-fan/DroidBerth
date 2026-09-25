#!/bin/bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

export TARGET_ARM="aarch64-apple-darwin"
export TARGET_INTEL="x86_64-apple-darwin"
export TARGET_UNIVERSAL="universal-apple-darwin"

export SIDECAR_NAME="droidberth-adb"
export APP_NAME="DroidBerth"

detect_bundle_dir() {
  if [ -n "${TARGET_TRIPLE:-}" ]; then
    printf '%s' "$ROOT/src-tauri/target/$TARGET_TRIPLE/release/bundle"
    return 0
  fi
  local candidates=(
    "$ROOT/src-tauri/target/aarch64-apple-darwin/release/bundle"
    "$ROOT/src-tauri/target/universal-apple-darwin/release/bundle"
    "$ROOT/src-tauri/target/x86_64-apple-darwin/release/bundle"
    "$ROOT/src-tauri/target/release/bundle"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -d "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  printf '%s' "$ROOT/src-tauri/target/aarch64-apple-darwin/release/bundle"
}

export_bundle_paths() {
  export BUNDLE_DIR="$(detect_bundle_dir)"
  export APP_PATH="$BUNDLE_DIR/macos/$APP_NAME.app"
  export DMG_DIR="$BUNDLE_DIR/dmg"
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
    "Apple Development"*|"Mac Developer"*) printf '%s' "apple-development" ;;
    "-") printf '%s' "adhoc" ;;
    *) printf '%s' "unknown" ;;
  esac
}

make_signed_dmg() {
  local app="$1" out="$2" identity
  identity="$(detect_identity)"
  rm -f "$out"
  hdiutil create -volname "$APP_NAME" -srcfolder "$app" -ov -format UDZO "$out" >/dev/null
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
