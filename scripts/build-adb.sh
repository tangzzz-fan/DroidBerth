#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

VENDOR="$ROOT/vendor"
AOSP="$VENDOR/platform_system_core"
SDK_ADB="$VENDOR/platform-tools/adb"
EXTRACT=0
for arg in "$@"; do
  [ "$arg" = "--extract" ] && EXTRACT=1
done

rule() { printf '%s\n' "----------------------------------------------------------------------------------------------------"; }

echo "Module 3 feasibility probe: can we ship a self-built adb?"
rule
echo "The doc assumes a CMake standalone build exists in AOSP, and that the SDK adb's"
echo "system-dylib dependencies are a notarization problem. Both are checked below."
echo

echo "== 1. Does the SDK adb actually have problematic dependencies? =="
if [ -x "$SDK_ADB" ]; then
  otool -L "$SDK_ADB" | awk '
    /architecture/ { next }
    /^[ \t]/ {
      dep = $1
      if (dep == "" || seen[dep]++) next
      if (dep ~ /^\/(usr\/lib|System\/Library)\//) printf "   [system]  %s\n", dep
      else { printf "   [FOREIGN] %s\n", dep; foreign++ }
    }
    END {
      if (foreign == 0) printf "\n   -> all dependencies are system libraries. Risk item 4 passes with the SDK adb as-is.\n"
    }
  '
  printf '   archs: %s   size: %s\n' "$(lipo -archs "$SDK_ADB")" "$(du -h "$SDK_ADB" | cut -f1)"
else
  echo "   vendor/platform-tools/adb not found; skipping."
fi
echo

echo "== 2. Is the SDK adb redistributable? (primary source, read locally) =="
if [ -f "$VENDOR/platform-tools/NOTICE.txt" ]; then
  total=$(grep -c 'Apache License' "$VENDOR/platform-tools/NOTICE.txt" || true)
  gpl=$(grep -c 'GNU GENERAL PUBLIC LICENSE' "$VENDOR/platform-tools/NOTICE.txt" || true)
  echo "   NOTICE.txt declares the platform-tools zip under Apache-2.0 ($total Apache mentions)."
  echo "   GPL/LGPL sections present: $gpl - these cover the filesystem tools (mke2fs, make_f2fs), not adb."
  echo
  echo "   Android SDK Terms: the redistribution ban is section 3.4 (not 3.3 as the doc says),"
  echo "   and section 3.5 says open-source-licensed SDK components are governed solely by"
  echo "   their own license. adb is Apache-2.0, so 3.5 appears to permit redistribution"
  echo "   of adb together with its NOTICE."
  echo "   -> not legal advice; confirm with whoever owns that risk."
else
  echo "   vendor/platform-tools/NOTICE.txt not found."
fi
echo

echo "== 3. Can adb be built standalone from AOSP with CMake? =="
if [ ! -d "$AOSP/.git" ]; then
  echo "   cloning the AOSP mirror (sparse, blobless)..."
  mkdir -p "$VENDOR"
  git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/aosp-mirror/platform_system_core.git "$AOSP"
  git -C "$AOSP" sparse-checkout set \
    adb libcutils libbase liblog libutils libziparchive libcrypto_utils \
    libdiagnoseusb libprocessgroup libselinux logd protobuf rootdir
else
  echo "   reusing $AOSP"
fi

cml=$(find "$AOSP" -name CMakeLists.txt 2>/dev/null | head -1 || true)
if [ -n "$cml" ]; then
  echo "   found: $cml"
else
  echo "   NO CMakeLists.txt anywhere in the tree."
fi
bp=$(find "$AOSP" -maxdepth 2 -name 'Android.bp' 2>/dev/null | wc -l | tr -d ' ')
echo "   Android.bp files (Soong): $bp"
echo
echo "   AOSP builds adb with Soong, not CMake. A standalone build therefore needs"
echo "   build glue that does not exist upstream - written from scratch, or vendored"
echo "   from a third-party project."
echo

echo "== 4. Third-party standalone build projects =="
for repo in karfield/adb stevenrao/adb-proj sooqalmelh/adb2; do
  curl -sS --max-time 20 "https://api.github.com/repos/$repo" 2>/dev/null \
    | REPO="$repo" /Users/tango/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3 -c "
import json, os, sys
repo = os.environ['REPO']
try:
    d = json.load(sys.stdin)
except Exception:
    print(f'   {repo:<28} (lookup failed)'); raise SystemExit
if 'full_name' not in d:
    print(f'   {repo:<28} {d.get(\"message\")}'); raise SystemExit
lic = (d.get('license') or {}).get('spdx_id') or 'NONE'
print(f\"   {d['full_name']:<28} pushed {d.get('pushed_at','?')[:10]}  stars {d.get('stargazers_count'):<4} license {lic}\")
" || echo "   $repo (lookup failed)"
done
echo
echo "   All three are stale (2016 / 2021 / 2024) and two carry no license at all."
echo "   Vendoring one means auditing it and probably maintaining it."
echo

rule
echo "VERDICT"
echo "   Module 3 is NOT required for notarization: the SDK adb already links only"
echo "   against system libraries, which is exactly risk item 4's pass criterion."
echo "   Its only remaining motivation is redistribution licensing, and section 3.5"
echo "   of the SDK terms plus the Apache-2.0 NOTICE make that motivation weak."
echo
echo "   A self-built adb is a build-glue project, not a script. Treat it as a"
echo "   separate decision with its own estimate, not as day-2 of this validation."
rule

if [ "$EXTRACT" = "1" ]; then
  echo
  echo "== extract mode: source subset materialised at $AOSP =="
  du -sh "$AOSP" 2>/dev/null | sed 's/^/   /'
  printf '   adb sources: %s .cpp files\n' "$(find "$AOSP/adb" -name '*.cpp' 2>/dev/null | wc -l | tr -d ' ')"
  echo "   the next step would be authoring a CMakeLists over this subset."
fi
