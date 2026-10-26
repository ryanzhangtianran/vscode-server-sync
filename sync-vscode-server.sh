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
FORCE=0
DO_LIST=0
DRY_RUN=0

usage() {
  cat <<'EOF'
用法: sync-vscode-server.sh [选项]

选项:
  --host <别名>     目标机（默认 HPC3）
  --commit <hash>   版本（默认本机 VS Code 的版本）
  --force           已存在也重传
  --list            列出本机已有版本
  --dry-run         只检查，不传输
  -h, --help        帮助

不带参数运行进入菜单。本机没有对应 server 时自动下载，传完即删。
EOF
}

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
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
  # 从 ~/.ssh/config 列出 Host 别名供选择（跳过通配符）；也可直接输入别名或地址
  # shortcut: 不展开 Include 进来的文件，有需要再加
  pick_host() {
    local hosts=() a i=1 h
    while read -r a; do hosts+=("$a"); done < <(
      awk 'tolower($1)=="host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' \
        ~/.ssh/config 2>/dev/null)
    clear 2>/dev/null || true
    echo "$line"
    row "选择目标机"
    if [ ${#hosts[@]} -gt 0 ]; then
      echo "$line"
      for a in "${hosts[@]}"; do
        row "${g}${i}.${r} ${a}$([ "$a" = "$REMOTE_HOST" ] && echo '（当前）')"
        i=$((i + 1))
      done
    fi
    echo "$line"
    read -rp "编号或地址 [$REMOTE_HOST]: " h || exit 0
    if [[ "$h" =~ ^[0-9]+$ ]] && [ "$h" -ge 1 ] && [ "$h" -le ${#hosts[@]} ]; then
      REMOTE_HOST="${hosts[$((h - 1))]}"
    else
      REMOTE_HOST="${h:-$REMOTE_HOST}"
    fi
  }
  pick_host
  while true; do
    local extra=()
    [ "$FORCE" = 1 ]       && extra+=(--force)
    clear 2>/dev/null || true
    echo "$line"
    row "VS Code Server 同步    目标机: ${g}${REMOTE_HOST}${r}"
    echo "$line"
    row "${g}1.${r} 同步当前版本"
    row "${g}2.${r} 同步指定版本"
    row "${g}3.${r} 本机已有版本"
    echo "$line"
    row "${g}4.${r} 切换目标机"
    row "${g}5.${r} 强制重传: $(onoff "$FORCE")"
    echo "$line"
    row "${g}0.${r} 退出"
    echo "$line"
    read -rp "选择 [0-5]: " choice || exit 0
    case "$choice" in
      1) bash "$0" --host "$REMOTE_HOST" ${extra[@]+"${extra[@]}"} || true ;;
      2) read -rp "commit（Help → About）: " c
         [ -n "$c" ] && { bash "$0" --host "$REMOTE_HOST" --commit "$c" ${extra[@]+"${extra[@]}"} || true; } ;;
      3) bash "$0" --list || true ;;
      4) pick_host; continue ;;
      5) FORCE=$((1 - FORCE)); continue ;;
      0) exit 0 ;;
      *) continue ;;
    esac
    echo "$line"
    read -rp "回车返回" _ || exit 0
  done
}

# 不带参数且在终端里运行时进入菜单
[ $# -eq 0 ] && [ -t 0 ] && menu

while [ $# -gt 0 ]; do
  case "$1" in
    --commit)   COMMIT="${2:-}"; shift 2 ;;
    --host)     REMOTE_HOST="${2:-}"; shift 2 ;;
    --download) shift ;;  # 旧参数，现在缺文件时总会下载
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
  log "本机已有版本"
  lru="$LOCAL_ROOT/cli/servers/lru.json"
  newest=""
  [ -r "$lru" ] && newest=$(grep -oE 'Stable-[0-9a-f]{40}' "$lru" | head -1 | sed 's/^Stable-//')
  list_local_commits | while read -r c; do
    size=$(du -sh "$LOCAL_ROOT/cli/servers/Stable-$c/server" 2>/dev/null | cut -f1)
    cli=$([ -f "$LOCAL_ROOT/code-$c" ] && echo "有 CLI" || echo "缺 CLI")
    mark=$([ "$c" = "$newest" ] && echo "（最近）" || echo "")
    printf '  %s  %-6s %-8s%s\n' "$c" "${size:-?}" "$cli" "$mark"
  done
  exit 0
fi

# ---------- 1. 确定 commit ----------
if [ -z "$COMMIT" ]; then
  # 优先用本机客户端的 commit：server 必须与它逐字节一致
  COMMIT=$(code --version 2>/dev/null | sed -n '2p' || true)
  for pj in "/Applications/Visual Studio Code.app/Contents/Resources/app/product.json" \
            /usr/share/code/resources/app/product.json; do
    [ -n "$COMMIT" ] && break
    [ -r "$pj" ] && COMMIT=$(grep -oE '"commit": *"[0-9a-f]{40}"' "$pj" | grep -oE '[0-9a-f]{40}' || true)
  done
  if [ -n "$COMMIT" ]; then
    log "版本 ${COMMIT}（本机 VS Code）"
  else
    lru="$LOCAL_ROOT/cli/servers/lru.json"
    [ -r "$lru" ] || die "找不到本机 VS Code，请用 --commit 指定版本"
    COMMIT=$(grep -oE 'Stable-[0-9a-f]{40}' "$lru" | head -1 | sed 's/^Stable-//')
    [ -n "$COMMIT" ] || die "解析 lru.json 失败，请用 --commit 指定版本"
    log "版本 ${COMMIT}（最近使用）"
  fi
else
  log "版本 $COMMIT"
fi

echo "$COMMIT" | grep -qE '^[0-9a-f]{40}$' || die "commit 应为 40 位十六进制"

# ---------- 2. 检查远端 ----------
log "连接 $REMOTE_HOST"
REMOTE_STATE=$(ssh -o BatchMode=yes "$REMOTE_HOST" "
  echo ARCH=\$(uname -m)
  s=\$HOME/$REMOTE_ROOT/cli/servers/Stable-$COMMIT/server
  c=\$HOME/$REMOTE_ROOT/code-$COMMIT
  [ -x \$s/bin/code-server ] && echo SERVER_OK || echo SERVER_MISSING
  [ -x \$c ] && echo CLI_OK || echo CLI_MISSING
  command -v rsync >/dev/null && echo RSYNC_OK || echo RSYNC_MISSING
") || die "无法连接 $REMOTE_HOST"

if echo "$REMOTE_STATE" | grep -q SERVER_OK && echo "$REMOTE_STATE" | grep -q CLI_OK && [ "$FORCE" = 0 ]; then
  log "已是最新，跳过（--force 强制重传）"
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
  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  SRC_SERVER="$STAGE/server"
  SRC_CLI="$STAGE/code"

  log "下载 server（linux-${ARCH}）"
  curl -fL --progress-bar "$UPDATE_API/commit:$COMMIT/server-linux-$ARCH/stable" \
    -o "$STAGE/server.tar.gz" || die "server 下载失败，检查网络"
  mkdir -p "$SRC_SERVER"
  tar -xzf "$STAGE/server.tar.gz" -C "$SRC_SERVER" --strip-components=1

  log "下载 CLI"
  curl -fL --progress-bar "$UPDATE_API/commit:$COMMIT/cli-linux-$ARCH/stable" \
    -o "$STAGE/cli.tar.gz" || die "CLI 下载失败，检查网络"
  tar -xzf "$STAGE/cli.tar.gz" -C "$STAGE"
  [ -f "$SRC_CLI" ] || die "CLI 包里没有 code"
  chmod 755 "$SRC_CLI"
  rm -f "$STAGE"/*.tar.gz
fi

SRC_SIZE=$(du -sh "$SRC_SERVER" | cut -f1)

if [ "$DRY_RUN" = 1 ]; then
  log "[dry-run] 将传输 $SRC_SIZE"
  exit 0
fi

# ---------- 4. 传输 ----------
ssh -o BatchMode=yes "$REMOTE_HOST" "mkdir -p \$HOME/$REMOTE_ROOT/cli/servers/Stable-$COMMIT"

if command -v rsync >/dev/null && echo "$REMOTE_STATE" | grep -q RSYNC_OK; then
  log "传输 server（${SRC_SIZE}）"
  # macOS 自带的 openrsync 不认 --info=progress2
  progress=--info=progress2
  rsync --info=progress2 --version >/dev/null 2>&1 || progress=
  rsync -a --partial $progress \
    "$SRC_SERVER/" "$REMOTE_HOST:$REMOTE_ROOT/cli/servers/Stable-$COMMIT/server/"

  log "传输 CLI"
  rsync -a --partial "$SRC_CLI" "$REMOTE_HOST:$REMOTE_ROOT/code-$COMMIT"
else
  # 有一端没装 rsync：用 tar 走 ssh，不能续传，中断了就整个重跑
  log "传输 server（${SRC_SIZE}，tar）"
  # COPYFILE_DISABLE/--no-xattrs：别把 macOS 的 ._* 和扩展属性带过去
  COPYFILE_DISABLE=1 tar --no-xattrs -czf - -C "$SRC_SERVER" . \
    | ssh -o BatchMode=yes "$REMOTE_HOST" "mkdir -p \$HOME/$REMOTE_ROOT/cli/servers/Stable-$COMMIT/server && tar -xzf - -C \$HOME/$REMOTE_ROOT/cli/servers/Stable-$COMMIT/server"

  log "传输 CLI"
  ssh -o BatchMode=yes "$REMOTE_HOST" "cat > \$HOME/$REMOTE_ROOT/code-$COMMIT" < "$SRC_CLI"
fi

# ---------- 5. 远端收尾 ----------
log "收尾"
ssh -o BatchMode=yes "$REMOTE_HOST" "
  set -e
  root=\$HOME/$REMOTE_ROOT
  chmod 755 \$root/code-$COMMIT \$root/cli/servers/Stable-$COMMIT/server/bin/code-server 2>/dev/null || true

  # 把本 commit 置顶写入 lru.json，保留原有其它条目（不依赖 python）
  lru=\$root/cli/servers/lru.json
  rest=\$(grep -oE '\"[^\"]+\"' \$lru 2>/dev/null | grep -vx '\"Stable-$COMMIT\"' | paste -sd, - || true)
  echo \"[\\\"Stable-$COMMIT\\\"\${rest:+,\$rest}]\" > \$lru

  # 删除下载失败留下的 0 字节包，否则客户端可能拿它当缓存
  find \$root -maxdepth 1 -name 'vscode-*.tar.gz' -size 0 -delete
"

# ---------- 6. 验证 ----------
log "验证"
ssh -o BatchMode=yes "$REMOTE_HOST" "
  root=\$HOME/$REMOTE_ROOT
  echo -n '  CLI:    '; \$root/code-$COMMIT --version 2>&1 | head -1
  echo -n '  Server: '; \$root/cli/servers/Stable-$COMMIT/server/bin/code-server --version 2>&1 | head -1
"

log "完成，可以连接 $REMOTE_HOST 了"
