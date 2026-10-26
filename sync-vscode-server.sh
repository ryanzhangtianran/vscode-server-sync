#!/usr/bin/env bash
# 把本机（有外网）的 VS Code Server 同步到任意无外网的 Linux 主机，
# 使 Remote-SSH 连接时无需下载即可直接启动。
#
# VS Code 1.86+ 的远端布局：
#   ~/.vscode-server/code-<commit>                        CLI 二进制
#   ~/.vscode-server/cli/servers/Stable-<commit>/server/  服务端本体
#   ~/.vscode-server/cli/servers/lru.json                 最近使用列表
set -euo pipefail

LOCAL_ROOT="$HOME/.vscode-server"
REMOTE_HOST="HPC3"
REMOTE_ROOT=".vscode-server"
UPDATE_API="https://update.code.visualstudio.com"

# uname -m -> 微软下载链接里的平台名
vscode_arch() {
  case "$1" in
    x86_64)        echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l)        echo armhf ;;
    *)             echo "unknown-$1" ;;
  esac
}
LOCAL_ARCH=$(vscode_arch "$(uname -m)")

COMMIT=""
DO_DOWNLOAD=0
FORCE=0
DO_LIST=0
DRY_RUN=0

usage() {
  cat <<'EOF'
用法: sync-vscode-server.sh [选项]

选项:
  --commit <hash>   指定要同步的 commit（默认取本地最近使用的那个）
  --host <别名>     目标主机的 ssh 别名或地址（默认 HPC3）
  --download        本机没有可用的该 commit 时，按目标机架构下载到临时目录，传完即删（需要代理可用）
  --force           目标已存在也重新同步
  --list            列出本地已有的 commit 后退出
  --dry-run         只显示将要执行的操作，不实际传输
  -h, --help        显示本帮助

说明:
  commit 必须与你本地 VS Code 客户端的版本一致，否则客户端仍会尝试下载。
  不带 --commit 时脚本读取 lru.json 的首项，也就是你最近一次用过的版本。
EOF
}

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# 交互菜单：每个选项都是用对应参数重新调用本脚本，子进程退出不影响菜单
menu() {
  local W=46 line g='\033[32m' r='\033[0m' choice c h
  line="+$(printf '%*s' "$W" '' | tr ' ' -)+"
  onoff() { [ "$1" = 1 ] && printf "${g}开${r}" || printf '关'; }
  # 带框的一行：按显示宽度补空格（中文占 2 格 = 3 字节减 1 个续字节/2）
  row() {
    local plain b cont
    plain=$(printf '%b' "$1" | sed $'s/\033\\[[0-9;]*m//g')
    b=$(printf %s "$plain" | LC_ALL=C wc -c)
    cont=$(printf %s "$plain" | LC_ALL=C tr -dc '\200-\277' | LC_ALL=C wc -c)
    printf "|  %b%*s|\n" "$1" $((W - 2 - b + cont / 2)) ''
  }
  while true; do
    local extra=()
    [ "$DO_DOWNLOAD" = 1 ] && extra+=(--download)
    [ "$FORCE" = 1 ]       && extra+=(--force)
    clear 2>/dev/null || true
    echo "$line"
    row "VS Code Server 同步工具"
    row "目标机: ${g}${REMOTE_HOST}${r}    本机架构: ${LOCAL_ARCH}"
    echo "$line"
    row "${g}1.${r} 同步最近使用的版本"
    row "${g}2.${r} 同步指定 commit"
    row "${g}3.${r} 列出本机版本"
    echo "$line"
    row "${g}4.${r} 切换目标机"
    row "${g}5.${r} 允许下载 (--download): $(onoff "$DO_DOWNLOAD")"
    row "${g}6.${r} 强制重传 (--force):    $(onoff "$FORCE")"
    echo "$line"
    row "${g}0.${r} 退出"
    echo "$line"
    read -rp "请输入选择 [0-6]: " choice || exit 0
    case "$choice" in
      1) bash "$0" --host "$REMOTE_HOST" ${extra[@]+"${extra[@]}"} || true ;;
      2) read -rp "commit（Help → About 里查）: " c
         [ -n "$c" ] && { bash "$0" --host "$REMOTE_HOST" --commit "$c" ${extra[@]+"${extra[@]}"} || true; } ;;
      3) bash "$0" --list || true ;;
      4) read -rp "目标机 ssh 别名或地址 [$REMOTE_HOST]: " h
         REMOTE_HOST="${h:-$REMOTE_HOST}"; continue ;;
      5) DO_DOWNLOAD=$((1 - DO_DOWNLOAD)); continue ;;
      6) FORCE=$((1 - FORCE)); continue ;;
      0) exit 0 ;;
      *) warn "无效选择: $choice" ;;
    esac
    echo "$line"
    read -rp "按回车返回菜单..." _ || exit 0
  done
}

# 不带参数且在终端里运行时进入菜单
[ $# -eq 0 ] && [ -t 0 ] && menu

while [ $# -gt 0 ]; do
  case "$1" in
    --commit)   COMMIT="${2:-}"; shift 2 ;;
    --host)     REMOTE_HOST="${2:-}"; shift 2 ;;
    --download) DO_DOWNLOAD=1; shift ;;
    --force)    FORCE=1; shift ;;
    --list)     DO_LIST=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "未知参数: $1（--help 查看用法）" ;;
  esac
done

list_local_commits() {
  [ -d "$LOCAL_ROOT/cli/servers" ] || return 0
  ls -1dt "$LOCAL_ROOT/cli/servers"/Stable-* 2>/dev/null \
    | sed 's|.*/Stable-||'
}

if [ "$DO_LIST" = 1 ]; then
  log "本地已有的 VS Code Server（按修改时间倒序）"
  lru="$LOCAL_ROOT/cli/servers/lru.json"
  newest=""
  [ -r "$lru" ] && newest=$(grep -oE 'Stable-[0-9a-f]{40}' "$lru" | head -1 | sed 's/^Stable-//')
  list_local_commits | while read -r c; do
    size=$(du -sh "$LOCAL_ROOT/cli/servers/Stable-$c/server" 2>/dev/null | cut -f1)
    cli=$([ -f "$LOCAL_ROOT/code-$c" ] && echo "有 CLI" || echo "缺 CLI")
    mark=$([ "$c" = "$newest" ] && echo "  <- 最近使用" || echo "")
    printf '  %s  %-6s %-8s%s\n' "$c" "${size:-?}" "$cli" "$mark"
  done
  exit 0
fi

# ---------- 1. 确定 commit ----------
if [ -z "$COMMIT" ]; then
  lru="$LOCAL_ROOT/cli/servers/lru.json"
  [ -r "$lru" ] || die "找不到 ${lru}，请用 --commit 显式指定"
  COMMIT=$(grep -oE 'Stable-[0-9a-f]{40}' "$lru" | head -1 | sed 's/^Stable-//')
  [ -n "$COMMIT" ] || die "无法从 lru.json 解析 commit，请用 --commit 显式指定"
  log "自动选定 commit: ${COMMIT}（本地最近使用）"
else
  log "指定 commit: $COMMIT"
fi

echo "$COMMIT" | grep -qE '^[0-9a-f]{40}$' || die "commit 格式不对，应为 40 位十六进制"

# ---------- 2. 检查远端 ----------
log "检查 $REMOTE_HOST 现状"
REMOTE_STATE=$(ssh -o BatchMode=yes "$REMOTE_HOST" "
  echo ARCH=\$(uname -m)
  s=\$HOME/$REMOTE_ROOT/cli/servers/Stable-$COMMIT/server
  c=\$HOME/$REMOTE_ROOT/code-$COMMIT
  [ -x \$s/bin/code-server ] && echo SERVER_OK || echo SERVER_MISSING
  [ -x \$c ] && echo CLI_OK || echo CLI_MISSING
") || die "无法连接 $REMOTE_HOST"

echo "$REMOTE_STATE" | sed 's/^/    /'

if echo "$REMOTE_STATE" | grep -q SERVER_OK && echo "$REMOTE_STATE" | grep -q CLI_OK && [ "$FORCE" = 0 ]; then
  log "远端已完整存在该版本，无需同步（--force 可强制重传）"
  exit 0
fi

# server 含原生二进制，必须按目标机架构准备
ARCH=$(vscode_arch "$(echo "$REMOTE_STATE" | sed -n 's/^ARCH=//p')")
case "$ARCH" in unknown-*) die "不支持的目标机架构: ${ARCH#unknown-}" ;; esac

SRC_SERVER="$LOCAL_ROOT/cli/servers/Stable-$COMMIT/server"
SRC_CLI="$LOCAL_ROOT/code-$COMMIT"

# ---------- 3. 准备源文件 ----------
# 同架构且本机已有完整的一份就直接复用，否则下载到临时目录，脚本退出时删掉
if [ "$ARCH" != "$LOCAL_ARCH" ] || [ ! -d "$SRC_SERVER" ] || [ ! -f "$SRC_CLI" ]; then
  if [ "$ARCH" != "$LOCAL_ARCH" ]; then
    log "目标机架构 $ARCH 与本机 $LOCAL_ARCH 不同，本机已有的 server 不能用"
  else
    [ -d "$SRC_SERVER" ] || warn "本机缺少 server: $SRC_SERVER"
    [ -f "$SRC_CLI" ]    || warn "本机缺少 CLI: $SRC_CLI"
  fi
  [ "$DO_DOWNLOAD" = 1 ] || die "加 --download 让脚本按目标机架构下载（传完自动删除），或用 --list 看看本机有哪些版本"

  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  SRC_SERVER="$STAGE/server"
  SRC_CLI="$STAGE/code"

  log "下载 linux-$ARCH server，commit:$COMMIT"
  curl -fL --progress-bar "$UPDATE_API/commit:$COMMIT/server-linux-$ARCH/stable" \
    -o "$STAGE/server.tar.gz" || die "server 下载失败（检查代理是否开启）"
  mkdir -p "$SRC_SERVER"
  tar -xzf "$STAGE/server.tar.gz" -C "$SRC_SERVER" --strip-components=1

  log "下载 linux-$ARCH CLI"
  curl -fL --progress-bar "$UPDATE_API/commit:$COMMIT/cli-linux-$ARCH/stable" \
    -o "$STAGE/cli.tar.gz" || die "CLI 下载失败（检查代理是否开启）"
  tar -xzf "$STAGE/cli.tar.gz" -C "$STAGE"
  [ -f "$SRC_CLI" ] || die "CLI 包结构异常，未找到 code 可执行文件"
  chmod 755 "$SRC_CLI"
  rm -f "$STAGE"/*.tar.gz
fi

SRC_SIZE=$(du -sh "$SRC_SERVER" | cut -f1)
log "源文件就绪: server $SRC_SIZE + CLI $(du -h "$SRC_CLI" | cut -f1)"

if [ "$DRY_RUN" = 1 ]; then
  log "[dry-run] 将传输 $SRC_SIZE 到 $REMOTE_HOST:~/$REMOTE_ROOT/"
  exit 0
fi

# ---------- 4. 传输 ----------
log "创建远端目录"
ssh -o BatchMode=yes "$REMOTE_HOST" "mkdir -p \$HOME/$REMOTE_ROOT/cli/servers/Stable-$COMMIT"

log "同步 server（${SRC_SIZE}，可中断续传）"
rsync -a --partial --info=progress2 \
  "$SRC_SERVER/" "$REMOTE_HOST:$REMOTE_ROOT/cli/servers/Stable-$COMMIT/server/"

log "同步 CLI 二进制"
rsync -a --partial "$SRC_CLI" "$REMOTE_HOST:$REMOTE_ROOT/code-$COMMIT"

# ---------- 5. 远端收尾 ----------
log "更新远端 lru.json 并清理下载残留"
ssh -o BatchMode=yes "$REMOTE_HOST" "
  set -e
  root=\$HOME/$REMOTE_ROOT
  chmod 755 \$root/code-$COMMIT \$root/cli/servers/Stable-$COMMIT/server/bin/code-server 2>/dev/null || true

  # 把本 commit 置顶写入 lru.json，保留原有其它条目
  python3 - <<PY
import json, os
p = os.path.expanduser('~/$REMOTE_ROOT/cli/servers/lru.json')
key = 'Stable-$COMMIT'
try:
    with open(p) as f: items = json.load(f)
except Exception:
    items = []
items = [key] + [i for i in items if i != key]
with open(p, 'w') as f: json.dump(items, f)
print('lru.json:', items)
PY

  # 删除下载失败留下的 0 字节包，否则客户端可能拿它当缓存
  find \$root -maxdepth 1 -name 'vscode-*.tar.gz' -size 0 -print -delete
"

# ---------- 6. 验证 ----------
log "验证远端"
ssh -o BatchMode=yes "$REMOTE_HOST" "
  root=\$HOME/$REMOTE_ROOT
  echo -n '  CLI:    '; \$root/code-$COMMIT --version 2>&1 | head -1
  echo -n '  Server: '; \$root/cli/servers/Stable-$COMMIT/server/bin/code-server --version 2>&1 | head -1
  echo -n '  大小:   '; du -sh \$root/cli/servers/Stable-$COMMIT/server | cut -f1
"

log "完成。现在用 VS Code Remote-SSH 连接 $REMOTE_HOST 应当直接启动，不再下载。"
