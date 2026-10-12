#!/bin/bash
# 构建矩阵守卫 —— **两个配置必须都还活着**。
#
# 守的是**第六种形态**的缺陷：**只在其中一条构建路径上出现的回归**。
# 侧载版构建一百次也不会发现 `Release-MAS` 块被误删、或它的 `CODE_SIGN_ENTITLEMENTS`
# 指错了文件 —— 那要等到**发 MAS 版那一刻**才暴露，而 MAS 的发布周期比侧载长得多
# （过了审核才发现更糟）。反过来，`Release` 坏了也是同理。
#
# 为什么默认是**静态**检查、而不是真跑两次构建：
# `check-all.sh` 的定位是 11 秒的快速门禁（不碰 Rust / adb），两次完整的 `xcodebuild`
# 要 1 分多钟。要真构建加 `--full`（发版前跑）。
#
# 静态恰恰能挡住最容易坏的那几处：配置块被删、类型写错（XcodeGen 按配置名推断设置预设，
# 写不清就拿不到 release 那套 ⇒ MAS 版**静默**用 `-Onone`）、entitlements 指错、
# 文件没列进工程、helper 漏 `inherit`（**这条本地测不出来**，只在审核被打回）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/macos/project.yml"
MAS_APP_ENT="$ROOT/macos/Resources/DroidBerth-MAS.entitlements"
MAS_HELPER_ENT="$ROOT/macos/Resources/Helper-MAS.entitlements"
SIDELOAD_ENT="$ROOT/macos/Resources/DroidBerth.entitlements"

FAILED=0
ok()  { echo "   ✓ $1"; }
bad() { echo "   ✗ $1"; FAILED=1; }

# 取 `project.yml` 里某个 target 级配置块的内容（8 空格缩进的那个 `Name:`）。
# 用 awk 而不是 `grep -A`：块的长度会变（`-A` 是个猜出来的数字）。
config_block() {
  awk -v want="        $1:" '
    index($0, want) == 1 { hit = 1; next }
    hit && /^        [A-Za-z]/ { hit = 0 }
    hit { print }
  ' "$PROJ"
}

echo "── check-build-matrix（project.yml 的配置矩阵）"

# ── 1. 顶层的三个配置，**类型必须显式** ────────────────────────────────
# 类型省略或写错 ⇒ XcodeGen 推断不出预设 ⇒ 该配置拿不到 `-O` / `wholemodule`。
for pair in "Debug debug" "Release release" "Release-MAS release"; do
  name="${pair%% *}"; kind="${pair##* }"
  if grep -qE "^  ${name}: ${kind}\$" "$PROJ"; then
    ok "顶层声明 ${name}: ${kind}（类型显式）"
  else
    bad "顶层缺 ${name}: ${kind} —— 类型省略或写错会让 XcodeGen 拿不到设置预设"
  fi
done

# ── 2. target 下的三个配置块都在 ───────────────────────────────────────
for name in Debug Release Release-MAS; do
  if grep -qE "^        ${name}:\$" "$PROJ"; then
    ok "target 级有 ${name} 块"
  else
    bad "target 级缺 ${name} 块"
  fi
done

# ── 3. 两侧各自指向正确的 entitlements ─────────────────────────────────
# 侧载版的在 `settings.base` 里；MAS 版在自己的块里覆盖。
if grep -qE "^        CODE_SIGN_ENTITLEMENTS: Resources/DroidBerth\.entitlements\$" "$PROJ"; then
  ok "base（侧载）指向 DroidBerth.entitlements"
else
  bad "base 的 CODE_SIGN_ENTITLEMENTS 不是侧载那份 —— 侧载版可能被套上沙盒"
fi

if config_block "Release-MAS" | grep -q "CODE_SIGN_ENTITLEMENTS: Resources/DroidBerth-MAS.entitlements"; then
  ok "Release-MAS 指向 DroidBerth-MAS.entitlements"
else
  bad "Release-MAS 没指向 MAS 的 entitlements —— 沙盒不会生效"
fi

if config_block "Release-MAS" | grep -q 'CODE_SIGN_IDENTITY: "Apple Distribution"'; then
  ok "Release-MAS 的身份是 Apple Distribution"
else
  bad "Release-MAS 的身份不是 Apple Distribution —— 那个包上不了 App Store"
fi

# ── 4. 三份 entitlements 都存在、且都为「可见可 review」列进了工程 ───────
for f in DroidBerth.entitlements DroidBerth-MAS.entitlements Helper-MAS.entitlements; do
  if [ -f "$ROOT/macos/Resources/$f" ]; then
    if grep -A1 "^      - path: Resources/${f}\$" "$PROJ" | grep -q "buildPhase: none"; then
      ok "$f 存在并列为 buildPhase: none"
    else
      bad "$f 没以 buildPhase: none 列进工程 —— 会进构建阶段或被静默忽略"
    fi
  else
    bad "缺文件 macos/Resources/$f"
  fi
done

# ── 5. 关键 entitlement 键（静态自查，产物级检查在 check-mas-readiness.sh）──
has_key() { grep -q "<key>$2</key>" "$1"; }
if has_key "$MAS_APP_ENT" "com.apple.security.app-sandbox"; then
  ok "app 的 entitlements 含 app-sandbox"
else
  bad "app 的 entitlements 缺 app-sandbox"
fi
if has_key "$MAS_HELPER_ENT" "com.apple.security.app-sandbox" \
   && has_key "$MAS_HELPER_ENT" "com.apple.security.inherit"; then
  ok "helper 的 entitlements 含 app-sandbox + inherit"
else
  # ⚠️ 这条**本地测不出来**：子进程在功能上本来就继承父的沙盒，漏了 inherit 一切照跑，
  #    只在 App Review 被打回时暴露。所以静态检查在这里比"跑一遍"更有用。
  bad "helper 的 entitlements 缺 app-sandbox 或 inherit（漏 inherit 只在审核时暴露）"
fi

# ── 6. --full：真的把两侧都构建一遍 ────────────────────────────────────
if [ "${1:-}" = "--full" ]; then
  echo
  echo "── 全量：真的构建两侧（约 1 分半）"
  # 逃逸参数与 check-all.sh 的 `sandbox_escape_args()` 同源：会话的沙盒能力会翻转，
  # 所以现测而不是写死（判据必须带 `allow process-exec`，程序用 /usr/bin/true）。
  ESCAPE=""
  if command -v sandbox-exec >/dev/null 2>&1; then
    code=0
    sandbox-exec -p '(version 1)(deny default)(allow file-read*)(allow process-exec)' /usr/bin/true >/dev/null 2>&1 || code=$?
    [ "${code}" != "0" ] && ESCAPE="-disable-sandbox"
  fi
  for cfg in Release Release-MAS; do
    args="OTHER_SWIFT_FLAGS=${ESCAPE:-}"
    [ -z "${ESCAPE}" ] && args=""
    [ "${cfg}" = "Release-MAS" ] && args="${args:+${args} }CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual"
    log="$(mktemp)"
    if CONFIGURATION="${cfg}" XCODEBUILD_ARGS="${args}" "$ROOT/scripts/build.sh" >"${log}" 2>&1; then
      ok "${cfg} BUILD SUCCEEDED"
    else
      bad "${cfg} 构建失败（日志 ${log}）"
      tail -12 "${log}" | sed 's/^/       /'
    fi
    rm -f "${log}"
  done
fi

echo
if [ "${FAILED}" = "1" ]; then
  echo "FAIL —— 配置矩阵有问题。两个产物都从这一个工程出来，任一侧坏掉都不该溜过。" >&2
  exit 1
fi
echo "ALL OK"
