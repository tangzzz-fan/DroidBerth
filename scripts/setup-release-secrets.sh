#!/bin/bash
# 把发布所需的 6 个 Repository secret 一次性写进 GitHub —— 「从本机搬凭据」的那一步。
#
#   ./scripts/setup-release-secrets.sh --p12 /路径/DeveloperID.p12
#
# 它不生成任何新凭据，也不打印任何凭据值。需要 `gh` 已登录，且对该仓库有 **admin** 权限
# （写 repository secret 的硬要求）。
#
# 三件直接取自 `.env`（`APPLE_ID` / `APPLE_PASSWORD` / `APPLE_TEAM_ID`）——
# 它们本来就在本机了，不必再去 appleid.apple.com 取一次。另三件是：
# 证书的 base64、p12 密码、CI 上临时钥匙串的密码（后两个只是给 CI 用的一次性字符串，
# 没人需要记住它们，所以缺省就现生成）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
source "$ROOT/scripts/env.sh"

P12=""
P12_PASSWORD="${P12_PASSWORD:-}"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --p12)           P12="${2:-}"; shift 2 ;;
    --p12-password)  P12_PASSWORD="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,12p' "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "没有 gh。装一个：brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh 未登录。先跑：gh auth login" >&2; exit 1; }

if [ -z "$P12" ] || [ ! -f "$P12" ]; then
  cat >&2 <<'EOF'
需要一份**只含 Developer ID 身份**的 .p12。导出方式（钥匙串访问）：

  1. 打开「钥匙串访问」→ 左边选「登录」→ 分类选「我的证书」
  2. 找到「Developer ID Application: zhenzhi Tang (UKXZ3FS84)」那一条
  3. 右键 → 导出… → 文件格式选 .p12 → 设一个密码 → 存到桌面
  4. 然后：
        ./scripts/setup-release-secrets.sh --p12 ~/Desktop/证书.p12

⚠️ **不要**用 `security export -t identities` 批量导出：那会把 Apple Development 与
   Apple Distribution 的私钥一并搬进 CI，而 CI 只需要 Developer ID 那一把
   （本机实测过：无 GUI 也能导出，但带出来的是全部三个身份）。
EOF
  exit 2
fi

for v in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
  if [ -z "$(printenv "$v" || true)" ]; then
    echo "缺少 $v —— 它应该由 .env 提供（见 scripts/env.sh 的 load_env_file）。" >&2
    exit 1
  fi
done

gen() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
[ -n "$P12_PASSWORD" ] || P12_PASSWORD="$(gen)"
[ -n "$KEYCHAIN_PASSWORD" ] || KEYCHAIN_PASSWORD="$(gen)"

# 值走 stdin（不写 --body），免得出现在进程列表里。
set_secret() {
  printf '%s' "$2" | gh secret set "$1" >/dev/null
  printf '  ✓ %s\n' "$1"
}

echo "写入 6 个 Repository secret："
set_secret BUILD_CERTIFICATE_BASE64    "$(base64 -i "$P12" | tr -d '\n')"
set_secret P12_PASSWORD                "$P12_PASSWORD"
set_secret KEYCHAIN_PASSWORD           "$KEYCHAIN_PASSWORD"
set_secret APPLE_ID                    "$APPLE_ID"
set_secret APPLE_APP_SPECIFIC_PASSWORD "$APPLE_PASSWORD"
set_secret APPLE_TEAM_ID               "$APPLE_TEAM_ID"

echo
echo "仓库里现在的 secret（只有名字与更新时间，值不会回读）："
gh secret list

cat <<'EOF'

下一步二选一：
  · 干跑（只构建 + 公证，产物作为 artifact，不发 Release）：
        gh workflow run release.yml -f version=0.0.0
  · 真发版：
        git tag v0.1.0 && git push origin v0.1.0
EOF
