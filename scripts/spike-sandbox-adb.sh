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
# App Sandbox 的本质是一份 `(deny default)` + 逐条放开 的 profile。而**受限会话**
# （比如 agent 自己跑在里面的那层沙箱）不允许再往下施加限制性 profile ——
# 内核直接拒：`sandbox-exec: sandbox_apply: Operation not permitted`，退出码 **71**。
#
# 症状极具误导性：被沙盒化的进程**一行输出都没有**就被信号打死（实测 ad-hoc 签名 SIGTRAP 133、
# Developer ID 签名 SIGKILL 137），因为它是**启动阶段**就死了，连缓冲里的东西都带不走。
# 只看现象会得出「沙盒挡住了 adb」这个**完全错误**的结论。
#
# 判据就用这条探针：宽松 profile 能施加、限制性 profile 报 71 ⇒ 本次运行不可信。
SANDBOX_APPLICABLE=1
if command -v sandbox-exec >/dev/null 2>&1; then
  probe_code=0
  sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok >/dev/null 2>&1 || probe_code=$?
  if [ "$probe_code" = "71" ]; then SANDBOX_APPLICABLE=0; fi
fi

echo "══ S1：沙盒里能不能跑内嵌的 adb"
echo "   工作目录 : $WORK"
echo "   端口     : ${PORT}（刻意避开 5037，不动你自己的 adb server）"
echo
if [ "$SANDBOX_APPLICABLE" = "0" ]; then
  echo "⚠️  ⚠️  ⚠️  这个终端**不允许施加限制性沙盒**（sandbox-exec 探针退出码 71）。"
  echo "       下面沙盒版一定会启动即被杀（且不留任何输出）—— 那是**环境**，不是沙盒策略的结论。"
  echo "       请在一个不受限的终端里重跑本脚本（你自己开的 iTerm / Terminal 就行）。"
  echo "       对照组仍然有效，会照常跑给你看。"
  echo
fi

rm -rf "$WORK"
mkdir -p "$WORK"

# ── 受限沙箱里的 swiftc 逃逸参数（与 check-all.sh 同一套判据）──────────────
sandbox_escape_args() {
  if ! command -v sandbox-exec >/dev/null 2>&1; then return 0; fi
  local code=0
  sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok >/dev/null 2>&1 || code=$?
  [ "$code" = "71" ] && printf '%s' "-Xfrontend -disable-sandbox"
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
  $ESCAPE \
  "$SCRIPT_DIR/main.swift"
echo "   ✓ 编译通过"

# ── entitlements ────────────────────────────────────────────────────────
# app 侧：沙盒 + 三类实际要用的权限。
cat > "$WORK/app-sandbox.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.device.usb</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
</dict>
</plist>
PLIST

# 内嵌 helper 侧：App Review 要求所有 main executable 都带 app-sandbox，
# 于是子进程要靠 `inherit` 才触发继承（沙盒本身与它无关 —— 子进程无论如何都继承父的）。
cat > "$WORK/helper-sandbox.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.inherit</key>
	<true/>
</dict>
</plist>
PLIST

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
codesign --force --sign - \
  --entitlements "$WORK/helper-sandbox.entitlements" \
  "$SANDBOX_APP/Contents/Resources/adb"
codesign --force --sign - \
  --entitlements "$WORK/app-sandbox.entitlements" \
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
"$CONTROL_APP/Contents/MacOS/ControlProbe" "$PORT" || true
echo
echo "───────────────────────────────────────────────────────────────"
echo "── 跑沙盒版"
echo
set +e
"$SANDBOX_APP/Contents/MacOS/SandboxProbe" "$PORT"
SANDBOX_STATUS=$?
set -e

# ── 收工：注销 LaunchServices 记录并删掉临时目录 ─────────────────────────
# KEEP=1 时保留现场 —— 探针被杀掉时必须能进到 bundle 里手工复现与换签名重试。
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ "${KEEP:-0}" != "1" ]; then
  if [ -x "$LSR" ]; then
    "$LSR" -u "$SANDBOX_APP" >/dev/null 2>&1 || true
    "$LSR" -u "$CONTROL_APP" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
else
  echo
  echo "（KEEP=1：现场保留在 ${WORK}，你自己记得删。）"
fi

# 收工时顺手清掉探针自己创建的那个 App Sandbox 容器 —— 留着就是一个幽灵。
#
# **容错**：某些环境会对 `~/Library` 下的删除做保护，删不掉不能把整个脚本带崩
# （`set -e` 下第一次 `rm` 失败就会中断，连结论都不打了）。删不掉就把路径打出来让人自己处理。
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

echo
echo "───────────────────────────────────────────────────────────────"
if [ "$SANDBOX_APPLICABLE" = "0" ]; then
  echo "**本次运行的沙盒版结论无效** —— 这个终端施加不了限制性沙盒，进程在启动阶段就被杀了。"
  echo "请在你自己的终端里重跑："
  echo
  echo "    cd $ROOT && ./scripts/spike-sandbox-adb.sh"
  echo
  echo "要拿到 S1-c（USB）的答案，还得插上**真机**并确认 USB 调试已授权。"
elif [ "$SANDBOX_STATUS" -eq 0 ]; then
  echo "S1-a / S1-b 通过。**S1-c（USB 那条）以沙盒版输出里的结论为准** ——"
  echo "只看到模拟器时必须报「未验证」：模拟器走 TCP，USB 通路根本没被走过。"
  echo "要拿到 S1-c 的答案：把**真机**插上、在手机上确认 USB 调试授权，然后重跑本脚本。"
else
  echo "S1-a 或 S1-b 失败（退出码 ${SANDBOX_STATUS}）。**先看沙盒版输出里「沙盒真的生效了吗」那一行**："
  echo "  · 若是「否」 —— 沙盒没挂上，这次结果什么都不能证明；"
  echo "  · 若是「是」 —— 沙盒确实挡住了，把输出贴进 docs/1011_04_appstore-plan.md §3 的 R1。"
fi
if [ "${KEEP:-0}" = "1" ]; then
  echo "（KEEP=1：现场保留在 ${WORK}，记得自己删。）"
else
  echo "（临时目录已删除，LaunchServices 记录已注销。）"
fi
