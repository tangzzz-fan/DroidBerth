#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

SDK_ADB="$ROOT/vendor/platform-tools/adb"

if [ ! -x "$SDK_ADB" ]; then
  echo "vendor/platform-tools/adb not found." >&2
  echo "Download it first:" >&2
  echo "  curl -L -o /tmp/pt.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip" >&2
  echo "  unzip -q /tmp/pt.zip -d $ROOT/vendor" >&2
  exit 1
fi

cat <<'EOF'
This copies the SDK platform-tools adb into src-tauri/binaries/ so the app can be
driven end-to-end against a real device.

  Use it for LOCAL VALIDATION ONLY.

Whether you may ship the SDK adb inside a distributed app is a licensing question,
not a technical one. See scripts/build-adb.sh, which reports what the SDK terms and
NOTICE.txt actually say. Do not treat this copy as a distribution decision.

EOF

mkdir -p "$ROOT/src-tauri/binaries"
for triple in "$TARGET_ARM" "$TARGET_INTEL" "$TARGET_UNIVERSAL"; do
  cp "$SDK_ADB" "$ROOT/src-tauri/binaries/adb-$triple"
done

printf 'copied (universal, %s):\n' "$(lipo -archs "$SDK_ADB")"
ls -1 "$ROOT/src-tauri/binaries/" | sed 's/^/  /'
echo
echo "next: scripts/build.sh --with-adb"
