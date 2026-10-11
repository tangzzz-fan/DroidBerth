#!/bin/bash
# S1 探针的**打包与对照**脚本 —— 回答一个问题：
#
#   沙盒里的 app，还能不能跑包内内嵌的 adb？还能不能看见 USB 上的真机？
#
# 为什么需要两个 bundle：**必须有对照组**。
# 只测沙盒版的话，「adb 失败」既可能是沙盒挡的，也可能是探针自己打包错了 ——
# 分不清的两件事等于没测。所以同时打一个**不带沙盒**的同构 bundle，两边跑同一段代码。
#
# 它回答三件互相独立的事（判据见 scripts/spike-sandbox-adb/main.swift 的注释）：
#   S1-a 沙盒里能不能执行包内的 adb
#   S1-b adb 的 server 能不能在沙盒里起在自定义端口
#   S1-c 沙盒里 adb 能不能通过 USB 看见**真机**（只看得到模拟器 ⇒ 未验证，模拟器走 TCP）
#
# 它是**只读探针**：不改仓库文件、不装任何东西、不碰你 `~/.android` 里的服务器
# （全程用 -P <自定义端口>）。跑完会注销自己注册的 bundle 并删掉临时目录。
#
# 用法：
#   ./scripts/spike-sandbox-adb.sh            # 默认端口 15037
#   ./scripts/spike-sandbox-adb.sh 16037      # 换端口（同时跑两次时用）
#
# 读结论时先看这一行：**「沙盒真的生效了吗」**。它若为「否」，上面的 PASS 一律不可信 ——
# 那说明沙盒根本没挂上，测的是一个普通 app。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/scripts/spike-sandbox-adb"
WORK="$ROOT/macos/build/spike-sandbox"
ADB_SOURCE="$ROOT/vendor/platform-tools/adb"
PORT="${1:-15037}"

# 刻意用**独立**的 bundle id：绝不能用 dev.tango.droidberth，
# 否则会在 LaunchServices 里多为真正的 app 留一条记录（这个坑本项目踩过 ——
# 见 docs/1011_05_engineering-notes.md §3「Dock 图标不换」）。
SANDBOX_BID="dev.tango.droidberth.sandboxprobe"
CONTROL_BID="dev.tango.droidberth.sandboxprobe.control"

if [ ! -x "$ADB_SOURCE" ]; then
  echo "找不到 vendor/platform-tools/adb —— 先跑 ./scripts/fetch-adb.sh" >&2
  exit 1
fi

# ── 预检：这个终端能不能施加**限制性**沙盒 ──────────────────────────────
#
# ⚠️ 这条判据**曾经写错过一次，而且错得非常有说服力** —— 记在这里免得再犯。
#
#   原判据  sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok
#   症状    退出码 71 + `execvp() of '/bin/echo' failed: Operation not permitted`
#   误读    以为「这个会话不允许嵌套限制性沙盒」
#   真因    那份 profile **没有 `allow process-exec`**，而 `sandbox-exec` 施加完 profile
#           之后**还要 exec 目标程序**。是 profile 自己拒绝了 exec ——
#           也就是说 profile **施加成功了**，结论与真实情况正好相反。
#
# 补上 `allow process-exec` 后同一条命令退出码 0。所以判据必须是**一个能正常跑起来的最小放开集**，
# 否则「profile 生效了」会被读成「profile 施加不了」。
#
# 这条误读付过代价：它让「本机做不了沙盒验证」被写进方案、工程笔记与项目记忆，
# 而实际上**沙盒版探针本机跑得完全正常**（S1-a / S1-b 当场就 PASS）。判据错一个方向，
# 挡住的是自己的路。
#
# 修正后的判据同时看两件事，避免再猜：退出码 + stderr 里有没有 `sandbox_apply`。
#
# ⚠️ 被施加的程序要写 **`/usr/bin/true`**：macOS **没有 `/bin/true`**（那是 Linux）。
#    路径写错同样报 71（`execvp() … No such file or directory`）—— **和判据写反的症状一模一样**，
#    所以这条也记在这里。短短一条探针能连错两次、两次都指向同一个错结论，值得当范例。
SANDBOX_APPLICABLE=1
SANDBOX_PROBE_DETAIL=""
if command -v sandbox-exec >/dev/null 2>&1; then
  probe_code=0
  probe_err="$(sandbox-exec -p '(version 1)(deny default)(allow file-read*)(allow process-exec)' /usr/bin/true 2>&1 >/dev/null)" || probe_code=$?
  if [ "$probe_code" != "0" ]; then
    SANDBOX_APPLICABLE=0
    SANDBOX_PROBE_DETAIL="退出码 ${probe_code}"
    [ -n "$probe_err" ] && SANDBOX_PROBE_DETAIL="${SANDBOX_PROBE_DETAIL} / ${probe_err}"
  fi
fi

echo "══ S1：沙盒里能不能跑内嵌的 adb"
echo "   工作目录 : $WORK"
echo "   端口     : ${PORT}（刻意避开 5037，不动你自己的 adb server）"
echo
if [ "$SANDBOX_APPLICABLE" = "0" ]; then
  echo "⚠️  ⚠️  ⚠️  这个终端**施加不了限制性沙盒**（探针：${SANDBOX_PROBE_DETAIL}）。"
  echo "       下面沙盒版会启动即被杀（且不留任何输出）—— 那是**环境**，不是沙盒策略的结论。"
  echo "       请在一个不受限的终端里重跑本脚本（你自己开的 iTerm / Terminal 就行）。"
  echo "       对照组仍然有效，会照常跑给你看。"
  echo
fi

rm -rf "$WORK"
mkdir -p "$WORK"

# ── swiftc 的沙箱逃逸参数（与 check-all.sh 同一套判据）─────────────────
# ⚠️ 判据同上：profile 必须自带 `allow process-exec`，且程序要写 `/usr/bin/true`
#    （macOS 没有 `/bin/true`，写错同样报 71）。
sandbox_escape_args() {
  if ! command -v sandbox-exec >/dev/null 2>&1; then return 0; fi
  local code=0
  sandbox-exec -p '(version 1)(deny default)(allow file-read*)(allow process-exec)' /usr/bin/true >/dev/null 2>&1 || code=$?
  [ "$code" != "0" ] && printf '%s' "-Xfrontend -disable-sandbox"
  return 0
}
ESCAPE="$(sandbox_escape_args)"
# 变量后紧跟中文标点必须写 ${} —— bash 3.2 会把全角字符的字节算进变量名。
[ -n "$ESCAPE" ] && echo "（检测到受限沙箱：给 swiftc 加 ${ESCAPE}）"

echo "── 1/4 编译探针"
# shellcheck disable=SC2086
swiftc -O -o "$WORK/probe" \
  -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 6 -strict-concurrency=complete \
  -framework IOKit \
  $ESCAPE \
  "$SCRIPT_DIR/main.swift"
echo "   ✓ 编译通过"

# ── entitlements：**直接读工程里那两份，不再自己抄一遍** ──────────────────
#
# 原先这里是两份内联 heredoc。改成引用 `macos/Resources/` 的那两份，理由是**唯一来源**：
# 探针要验的就是「要发的这一套 entitlements」，抄一份的后果是两者会分叉，
# 而分叉的表现是「探针过了、真 app 没过」—— 最坏的一种：**它给了你绿灯**。
MAS_ENTITLEMENTS="$ROOT/macos/Resources/DroidBerth-MAS.entitlements"
HELPER_ENTITLEMENTS="$ROOT/macos/Resources/Helper-MAS.entitlements"
for plist_file in "$MAS_ENTITLEMENTS" "$HELPER_ENTITLEMENTS"; do
  if [ ! -f "$plist_file" ]; then
    echo "找不到 ${plist_file} —— 探针要拿它当沙盒权限的来源，不能缺" >&2
    exit 1
  fi
  plutil -lint "$plist_file" >/dev/null || { echo "${plist_file} 不是合法 plist" >&2; exit 1; }
done
echo "权限来源（唯一来源，与 MAS 版共用）："
echo "  app    : ${MAS_ENTITLEMENTS#$ROOT/}"
echo "  helper : ${HELPER_ENTITLEMENTS#$ROOT/}"

make_bundle() {
  local name="$1" bid="$2"
  local app="$WORK/$name.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$WORK/probe" "$app/Contents/MacOS/$name"
  cp "$ADB_SOURCE" "$app/Contents/Resources/adb"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>${bid}</string>
	<key>CFBundleExecutable</key><string>${name}</string>
	<key>CFBundleName</key><string>${name}</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
  plutil -lint "$app/Contents/Info.plist" >/dev/null
  printf '%s' "$app"
}

echo "── 2/4 组装两个 bundle（沙盒版 + 对照组）"
SANDBOX_APP="$(make_bundle SandboxProbe "$SANDBOX_BID")"
CONTROL_APP="$(make_bundle ControlProbe "$CONTROL_BID")"

echo "── 3/4 签名（ad-hoc；对内嵌 adb 先签，再由外向内签 app）"
# 由内向外：helper 带 `inherit` → app 带沙盒权限。顺序反了会把 app 的封装破坏掉。
codesign --force --sign - \
  --entitlements "$HELPER_ENTITLEMENTS" \
  "$SANDBOX_APP/Contents/Resources/adb"
codesign --force --sign - \
  --entitlements "$MAS_ENTITLEMENTS" \
  "$SANDBOX_APP"

# 对照组：adb 与 app 都不带 entitlements（父进程本来就不是沙盒，子进程自然也不是）。
codesign --force --sign - "$CONTROL_APP/Contents/Resources/adb"
codesign --force --sign - "$CONTROL_APP"

echo "   沙盒版 app 的 entitlements："
codesign -d --entitlements - "$SANDBOX_APP" 2>/dev/null | sed 's/^/     /'
echo "   沙盒版 adb 的 entitlements："
codesign -d --entitlements - "$SANDBOX_APP/Contents/Resources/adb" 2>/dev/null | sed 's/^/     /'

echo
echo "── 4/4 跑对照组（先跑它：它是「探针自己能跑通」的证据）"
echo
# 两次运行的输出都**落文件再打印**，不用管道。
# 原因有两个，都踩过：① 管道会块缓冲，探针在启动阶段被杀时缓冲里的输出全丢 ——
# 现象就是「一行输出都没有」，完全看不出死在哪一步；② 我们要从输出里取 USB-COUNT
# 与对照组比，必须留得下来。
set +e
"$CONTROL_APP/Contents/MacOS/ControlProbe" "$PORT" > "$WORK/control.out" 2>&1
CONTROL_STATUS=$?
set -e
cat "$WORK/control.out"
echo
echo "───────────────────────────────────────────────────────────────"
echo "── 跑沙盒版"
echo
set +e
"$SANDBOX_APP/Contents/MacOS/SandboxProbe" "$PORT" > "$WORK/sandbox.out" 2>&1
SANDBOX_STATUS=$?
set -e
cat "$WORK/sandbox.out"

# ── USB-COUNT 对比（辅助判据）──────────────────────────────────────────
# 取两次输出里那个稳定的机器可读行。同样用 awk 不用 `sed | head`（理由见下方 machine_get）。
# `|| true` 是为了可能一行都没有（进程在启动阶段就被杀掉）时不把脚本带崩。
usb_count_of() {
  awk '/^USB-COUNT: /{ print substr($0, 12); exit }' "$1" 2>/dev/null || true
}
control_usb="$(usb_count_of "$WORK/control.out")"
sandbox_usb="$(usb_count_of "$WORK/sandbox.out")"
control_usb="${control_usb:-?}"
sandbox_usb="${sandbox_usb:-?}"
USB_VERDICT="未取到"
if [ "$control_usb" != "?" ] && [ "$sandbox_usb" != "?" ]; then
  if [ "$sandbox_usb" = "-1" ]; then
    USB_VERDICT="**枚举被拒** —— device.usb 没生效"
  elif [ "$sandbox_usb" = "0" ] && [ "$control_usb" != "0" ]; then
    USB_VERDICT="**沙盒里 0 个，对照组 ${control_usb} 个 —— 通路被挡**"
  elif [ "$sandbox_usb" = "$control_usb" ]; then
    USB_VERDICT="通路成立（沙盒 ${sandbox_usb} 个 = 对照组 ${control_usb} 个）"
  else
    USB_VERDICT="数量不一致（沙盒 ${sandbox_usb} vs 对照组 ${control_usb}）—— 需要复核"
  fi
fi

# ── 结论汇总 ───────────────────────────────────────────────────────────
# 只读探针打的那几行 `MACHINE xxx=yyy`，不去猜上面那些带全角空格的正文 ——
# 正文是给人看的，改排版就会让解析静默失效。
#
# ⚠️ 取「第一行」**必须用 awk 的 exit，不能用 `sed … | head -1`**：
#    在 `set -e` + `pipefail` 下，`head` 提前退出会让 `sed` 收 SIGPIPE（141），
#    于是赋值语句整体失败、脚本直接中断 —— 而且是**竞态**，取决于两者谁先跑完，
#    上一次跑通了下一次就未必（本项目实测到过一次）。
machine_get() {
  awk -v key="MACHINE $1=" 'index($0, key) == 1 { print substr($0, length(key) + 1); exit }' "$2" 2>/dev/null || true
}
sb_a="$(machine_get 'S1-a' "$WORK/sandbox.out")"; sb_a="${sb_a:-?}"
sb_b="$(machine_get 'S1-b' "$WORK/sandbox.out")"; sb_b="${sb_b:-?}"
sb_c="$(machine_get 'S1-c' "$WORK/sandbox.out")"; sb_c="${sb_c:-?}"
sb_box="$(machine_get 'sandbox' "$WORK/sandbox.out")"; sb_box="${sb_box:-?}"

echo
echo "───────────────────────────────────────────────────────────────"
echo "── S1 判定（沙盒版；对照组只用来证明「探针本身没坏」）"
echo "  S1-a 沙盒内执行包内 adb  : ${sb_a}"
echo "  S1-b 沙盒内 adb server   : ${sb_b}"
echo "  S1-c 沙盒内经 USB 见真机 : ${sb_c}"
echo "  S1-c′ USB 通路（辅助）   : ${USB_VERDICT}"
echo "  判据自检 沙盒真的生效吗  : ${sb_box}"
echo

if [ "$SANDBOX_APPLICABLE" = "0" ] || [ "$sb_box" = "no" ]; then
  echo "**本次沙盒版结论无效** —— 进程没有被沙盒化（或这个终端施加不了限制性沙盒）。"
  echo "探针详情：${SANDBOX_PROBE_DETAIL:-（无）}"
  echo "在你自己不受限的终端里重跑："
  echo
  echo "    cd $ROOT && ./scripts/spike-sandbox-adb.sh"
elif [ "$sb_a" = "PASS" ] && [ "$sb_b" = "PASS" ]; then
  echo "S1-a / S1-b **通过**：沙盒里能执行包内 adb，server 也能起在自定义端口上。"
  echo "剩下只有 **S1-c** —— 它必须有真机：插上手机、在手机上确认 USB 调试授权后重跑。"
  echo "辅助判据那条可以先看：它若已「通路成立」，S1-c 基本只剩设备那一侧的事。"
else
  echo "S1-a 或 S1-b **失败** —— 这才是真正该写进 docs/1011_04_appstore-plan.md §3 R1 的结论。"
  echo "先看上面沙盒版输出里「判据自检 沙盒真的生效吗」那一行：为「否」则本次结果什么都不能证明。"
fi

# ── 收工：注销 LaunchServices 记录、删临时目录、清探针容器 ────────────────
#
# ⚠️ **必须在结论汇总之后**。这些清理要删掉 `$WORK`，而汇总正是去读
#    `$WORK/sandbox.out` 与 `control.out` —— 先删就会出现「汇总全是 ?」，
#    而且**不报错**，只是静默变空。本项目实测踩过一次（USB 那组因为排在清理之前才侥幸读到）。
#
# KEEP=1 时保留现场 —— 探针被杀掉时必须能进到 bundle 里手工复现与换签名重试。
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ "${KEEP:-0}" != "1" ]; then
  if [ -x "$LSR" ]; then
    "$LSR" -u "$SANDBOX_APP" >/dev/null 2>&1 || true
    "$LSR" -u "$CONTROL_APP" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
fi

# 顺手清掉探针自己创建的那个 App Sandbox 容器 —— 留着就是一个幽灵。
#
# **容错**：某些环境会对 `~/Library` 下的删除做保护（本项目的 agent 会话就是），
# 删不掉不能把整个脚本带崩（`set -e` 下第一次 `rm` 失败就会中断，连结论都不打了）。
# 删不掉就把路径打出来让人自己处理。
CONTAINER="$HOME/Library/Containers/$SANDBOX_BID"
if [ -d "$CONTAINER" ]; then
  echo
  if rm -rf "$CONTAINER" 2>/dev/null; then
    echo "（清掉探针自己创建的容器：${CONTAINER}）"
  else
    echo "（容器没能自动删掉 —— 它只是探针自己的，留着无害。想清掉就手动：）"
    echo "    rm -rf \"$CONTAINER\""
  fi
fi

if [ "${KEEP:-0}" = "1" ]; then
  echo "（KEEP=1：现场保留在 ${WORK}，记得自己删。）"
else
  echo "（临时目录已删除，LaunchServices 记录已注销。）"
fi

# ── 退出码 ─────────────────────────────────────────────────────────────
# 只表达一件事：**S1-a / S1-b 在真正生效的沙盒里通过了**。
# 环境不可信（沙盒没挂上 / 施加不了）也返回非 0 —— 那种情况下「通过」不成立，
# 不能让调用方（CI、以后的脚本）把它当成绿灯。
if [ "$SANDBOX_APPLICABLE" = "1" ] && [ "$sb_box" = "yes" ] \
   && [ "$sb_a" = "PASS" ] && [ "$sb_b" = "PASS" ]; then
  exit 0
fi
exit 1
