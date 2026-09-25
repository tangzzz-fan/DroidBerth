#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

UNIVERSAL=0
for arg in "$@"; do
  [ "$arg" = "--universal" ] && UNIVERSAL=1
done

require_rust
mkdir -p "$ROOT/src-tauri/binaries"

for target in "$TARGET_ARM" "$TARGET_INTEL"; do
  echo "==> building $SIDECAR_NAME for $target"
  cargo build --release --manifest-path "$ROOT/sidecar/$SIDECAR_NAME/Cargo.toml" --target "$target"
  cp "$ROOT/sidecar/$SIDECAR_NAME/target/$target/release/$SIDECAR_NAME" \
     "$ROOT/src-tauri/binaries/$SIDECAR_NAME-$target"
done

if [ "$UNIVERSAL" = "1" ]; then
  echo "==> lipo -> $SIDECAR_NAME-$TARGET_UNIVERSAL"
  lipo -create \
    "$ROOT/src-tauri/binaries/$SIDECAR_NAME-$TARGET_ARM" \
    "$ROOT/src-tauri/binaries/$SIDECAR_NAME-$TARGET_INTEL" \
    -output "$ROOT/src-tauri/binaries/$SIDECAR_NAME-$TARGET_UNIVERSAL"
fi

echo
echo "sidecars in src-tauri/binaries:"
for f in "$ROOT/src-tauri/binaries/"*; do
  [ -f "$f" ] || continue
  printf '  %-46s %s  archs=%s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" "$(lipo -archs "$f")"
done
echo
echo "note: these are deliberately left unsigned so that Tauri's own signing step can be observed."
