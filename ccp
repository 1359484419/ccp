#!/usr/bin/env bash
# ccp - Claude Code profile 管理器（macOS / Linux）
# 每个 profile 是一个独立的 CLAUDE_CONFIG_DIR，对应一个账号，登录态/会话/设置互相隔离。
set -euo pipefail

CCP_VERSION="1.4.0"
REPO_RAW="${CCP_REPO_RAW:-https://raw.githubusercontent.com/1359484419/ccp/main}"
ROOT="${CCP_HOME:-$HOME/.claude-profiles}"
DEFAULT_DIR="$HOME/.claude"
# share 子命令默认从 ~/.claude 软链接过来的条目（不含凭证和账号状态）
SHARE_ITEMS=(CLAUDE.md skills commands agents)

die() { echo "ccp: $*" >&2; exit 1; }

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || die "profile 名只能包含字母、数字、- 和 _：'$1'"
}

profile_dir() { echo "$ROOT/$1"; }

require_profile() {
  valid_name "$1"
  [[ -d "$(profile_dir "$1")" ]] || die "profile '$1' 不存在，先运行：ccp add $1"
}

# 名字对应的配置目录；default 表示直接运行 claude 时用的 ~/.claude
config_dir_of() {
  if [[ "$1" == "default" ]]; then echo "$DEFAULT_DIR"; return; fi
  require_profile "$1"
  profile_dir "$1"
}

# 从 profile 的 .claude.json 读出登录邮箱；未登录输出空
account_of() {
  local f="$1/.claude.json"
  [[ -f "$f" ]] || return 0
  grep -o '"emailAddress": *"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*: *"\(.*\)"/\1/' || true
}

cmd_add() {
  [[ $# -ge 1 ]] || die "用法：ccp add <name>"
  valid_name "$1"
  [[ "$1" != "default" ]] || die "default 是保留名（指直接运行 claude 时的账号），请换个名字"
  local d; d="$(profile_dir "$1")"
  if [[ -d "$d" ]]; then
    echo "profile '$1' 已存在：$d"
  else
    mkdir -p "$d"
    echo "已创建 profile '$1'：$d"
  fi
  echo "下一步：ccp login $1  登录该账号"
}

cmd_list() {
  [[ -d "$ROOT" ]] || { echo "还没有 profile，先运行：ccp add <name>"; return 0; }
  local found=0 d name acct mark
  printf "%-2s %-16s %s\n" "" "PROFILE" "ACCOUNT"
  for d in "$ROOT"/*/; do
    [[ -d "$d" ]] || continue
    found=1
    d="${d%/}"; name="${d##*/}"
    acct="$(account_of "$d")"
    mark=""; [[ "${CLAUDE_CONFIG_DIR:-}" == "$d" ]] && mark="*"
    printf "%-2s %-16s %s\n" "$mark" "$name" "${acct:-（未登录）}"
  done
  [[ $found -eq 1 ]] || echo "还没有 profile，先运行：ccp add <name>"
  acct="$(account_of "$HOME")"
  printf "%-2s %-16s %s\n" "" "(default)" "${acct:-（未登录）}  ← 直接运行 claude 时使用"
}

cmd_run() {
  [[ $# -ge 1 ]] || die "用法：ccp run <name> [claude 参数...]"
  local name="$1" d; d="$(config_dir_of "$name")"; shift
  command -v claude >/dev/null || die "找不到 claude 命令，请先安装 Claude Code"
  if [[ "$name" == "default" ]]; then
    unset CLAUDE_CONFIG_DIR
    CCP_PROFILE=default exec claude "$@"
  fi
  CLAUDE_CONFIG_DIR="$d" CCP_PROFILE="$name" exec claude "$@"
}

# 默认不自动打开浏览器：claude 只打印登录链接，复制到任意设备的浏览器打开，再把授权码粘贴回来。
# 用户已设置 BROWSER 时尊重其设置。
cmd_login() {
  [[ $# -ge 1 ]] || die "用法：ccp login <name> [claude auth login 参数...]"
  local name="$1" d; d="$(config_dir_of "$name")"; shift
  command -v claude >/dev/null || die "找不到 claude 命令，请先安装 Claude Code"
  if [[ -z "${BROWSER:-}" ]]; then
    local f; for f in /usr/bin/false /bin/false; do [[ -x "$f" ]] && break; done
    export BROWSER="$f"
  fi
  echo "请复制下面打印的链接到浏览器打开，登录后把授权码粘贴回来"
  # default 不设 CLAUDE_CONFIG_DIR（外层 shell 设置过也要清掉），即登录 ~/.claude
  if [[ "$name" == "default" ]]; then
    unset CLAUDE_CONFIG_DIR
    CCP_PROFILE=default exec claude auth login "$@"
  fi
  CLAUDE_CONFIG_DIR="$d" CCP_PROFILE="$name" exec claude auth login "$@"
}

# Claude Code 按项目路径存会话：路径中字母数字以外的字符都换成 -
project_key() { printf '%s' "$(pwd -P)" | sed 's/[^A-Za-z0-9]/-/g'; }

# 至少有一条 AI 回复才算真正的会话。只打开过 claude、或只执行过 /clear、/model 等命令也会生成会话文件，但里面没有对话
has_reply() { grep -q '"type":"assistant"' "$1"; }

# 会话标题：优先用 claude 生成的标题，没有则用最后一次输入的内容
session_title() {
  local t
  t="$(grep -o '"aiTitle":"[^"]*"' "$1" | tail -1 | cut -d'"' -f4)"
  [[ -n "$t" ]] || t="$(grep -o '"lastPrompt":"[^"]*"' "$1" | tail -1 | cut -d'"' -f4)"
  printf '%s' "${t:0:60}"
}

session_line() {
  printf '%s  %s  %s\n' "$(basename "$1" .jsonl)" "$(date -r "$1" '+%Y-%m-%d %H:%M')" "$(session_title "$1")"
}

# 列出 <name> 在当前项目下的会话（新的在前），空会话不列出
cmd_sessions() {
  [[ $# -ge 1 ]] || die "用法：ccp sessions <name>"
  local dir f n=0 empty=0
  dir="$(config_dir_of "$1")/projects/$(project_key)"
  [[ -d "$dir" ]] || die "'$1' 在当前目录（${PWD}）下没有会话"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if has_reply "$f"; then session_line "$f"; n=$((n+1)); else empty=$((empty+1)); fi
  done < <(ls -t "$dir"/*.jsonl 2>/dev/null)
  [[ $n -gt 0 ]] || echo "'$1' 在当前目录下没有包含对话的会话"
  [[ $empty -eq 0 ]] || echo "（另有 ${empty} 个没有对话内容的会话未列出）"
  return 0
}

# 把 <from> 在当前项目下最近的（或指定的）会话复制到 <to>，然后用 <to> 接着这个会话
# <to> 已有同名会话时：内容相同则直接接着跑；<to> 的更新则拒绝（除非 --force）；否则先备份为 .bak 再覆盖
cmd_take() {
  [[ $# -ge 2 ]] || die "用法：ccp take <from> <to> [--session <id>] [--force] [claude 参数...]"
  config_dir_of "$1" >/dev/null; config_dir_of "$2" >/dev/null
  [[ "$1" != "$2" ]] || die "<from> 和 <to> 不能相同"
  local from="$1" to="$2"; shift 2
  local sid="" force=0
  # 选项顺序任意；遇到第一个不认识的参数即视为 claude 参数开始
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session)
        [[ -n "${2:-}" ]] || die "--session 后面需要会话 ID"
        # 会话 ID 会拼进路径，只允许字母、数字、- 和 _，防止 ../ 之类越出会话目录
        [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] || die "会话 ID 格式不对：'$2'"
        sid="$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) break ;;
    esac
  done
  local key; key="$(project_key)"
  local src_dir dst_dir
  src_dir="$(config_dir_of "$from")/projects/$key"
  dst_dir="$(config_dir_of "$to")/projects/$key"
  [[ -d "$src_dir" ]] || die "'$from' 在当前目录（${PWD}）下没有会话"
  if [[ -z "$sid" ]]; then
    # 取最近一个有对话的会话，跳过空会话（否则额度用完后再打开一次 claude，就会选中那个空会话）
    local f latest="" skipped=0
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if has_reply "$f"; then latest="$f"; break; fi
      skipped=$((skipped+1))
    done < <(ls -t "$src_dir"/*.jsonl 2>/dev/null)
    [[ -n "$latest" ]] || die "'$from' 在当前目录下没有包含对话的会话"
    sid="$(basename "$latest" .jsonl)"
    [[ $skipped -eq 0 ]] || echo "已跳过 ${skipped} 个更新但没有对话内容的会话"
  fi
  [[ -f "$src_dir/$sid.jsonl" ]] || die "'$from' 在当前目录下找不到会话 ${sid}（用 ccp sessions $from 查看）"
  local src="$src_dir/$sid.jsonl" dst="$dst_dir/$sid.jsonl"
  echo "会话：$(session_line "$src")"
  if [[ -f "$dst" ]]; then
    if cmp -s "$src" "$dst"; then
      echo "'$to' 里的会话 $sid 已是最新（与 '$from' 相同），无需复制，正在接着运行…"
      cmd_run "$to" --resume "$sid" "$@"
    fi
    # 目标更新说明已在 <to> 上接着跑过，直接覆盖会丢进度
    if [[ $force -eq 0 && "$dst" -nt "$src" ]]; then
      die "'$to' 里的会话 $sid 比 '$from' 的更新（可能已在 '$to' 上继续过），为避免覆盖进度已停止；确认覆盖请加 --force"
    fi
    cp -p "$dst" "$dst.bak"
    echo "'$to' 里已有会话 ${sid}，已备份到：$dst.bak"
  fi
  mkdir -p "$dst_dir"
  cp "$src" "$dst_dir/"
  # 部分版本会把子代理等记录放在同名目录里，一并复制
  [[ -d "$src_dir/$sid" ]] && cp -R "$src_dir/$sid" "$dst_dir/"
  echo "已把 '$from' 的会话 $sid 复制到 '$to'，正在接着运行…"
  cmd_run "$to" --resume "$sid" "$@"
}

cmd_env() {
  [[ $# -ge 1 ]] || die "用法：eval \"\$(ccp env <name>)\""
  if [[ "$1" == "default" ]]; then
    printf 'unset CLAUDE_CONFIG_DIR\nexport CCP_PROFILE=default\n'
    return 0
  fi
  require_profile "$1"
  printf 'export CLAUDE_CONFIG_DIR=%q\nexport CCP_PROFILE=%q\n' "$(profile_dir "$1")" "$1"
}

cmd_share() {
  [[ $# -ge 1 ]] || die "用法：ccp share <name> [条目...]   默认：${SHARE_ITEMS[*]}"
  [[ "$1" != "default" ]] || die "default 是保留名（就是 ${DEFAULT_DIR} 本身），不需要共享"
  require_profile "$1"
  local d; d="$(profile_dir "$1")"; shift
  local items=("${SHARE_ITEMS[@]}")
  [[ $# -gt 0 ]] && items=("$@")
  local it src dst
  for it in "${items[@]}"; do
    case "$it" in
      .claude.json|.credentials.json|projects|sessions|history.jsonl)
        echo "跳过 ${it}：账号/会话数据不能共享"; continue ;;
    esac
    src="$DEFAULT_DIR/$it"; dst="$d/$it"
    if [[ ! -e "$src" ]]; then
      echo "跳过 ${it}：$src 不存在"
    elif [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
      echo "已链接 $it"
    elif [[ -e "$dst" || -L "$dst" ]]; then
      echo "跳过 ${it}：$dst 已存在（profile 自有版本，不覆盖）"
    else
      ln -s "$src" "$dst"
      echo "链接 $it -> $src"
    fi
  done
}

cmd_rm() {
  [[ $# -ge 1 ]] || die "用法：ccp rm <name>"
  valid_name "$1"
  [[ "$1" != "default" ]] || die "default 是保留名（指直接运行 claude 时的 ${DEFAULT_DIR}），不能删除"
  local d; d="$(profile_dir "$1")"
  [[ -d "$d" ]] || { echo "profile '$1' 不存在，无需删除"; return 0; }
  local acct; acct="$(account_of "$d")"
  local ans=""
  # stdin 已关闭（如脚本里调用）时 read 会失败，按"取消"处理，不能让 set -e 静默退出
  read -r -p "删除 profile '$1'（${acct:-未登录}），包括其会话历史？[y/N] " ans || ans=""
  [[ "$ans" == [yY] ]] || { echo "已取消"; return 0; }
  # 只删目录本身；共享条目是软链接，rm -rf 不会跟随到 ~/.claude
  rm -rf "$d"
  echo "已删除 $d"
  [[ "$(uname)" == "Darwin" ]] && echo "提示：macOS 钥匙串中可能残留该账号凭证，可在『钥匙串访问』里搜索 Claude Code 手动清理"
  return 0
}

cmd_current() {
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    echo "${CLAUDE_CONFIG_DIR##*/}  ($CLAUDE_CONFIG_DIR)  $(account_of "$CLAUDE_CONFIG_DIR")"
  else
    echo "(default)  ($DEFAULT_DIR)  $(account_of "$HOME")"
  fi
}

# 按 x.y.z 数字逐段比较版本：输出 -1 / 0 / 1（$1 小于 / 等于 / 大于 $2）
ver_cmp() {
  local IFS=.
  local a=($1) b=($2) i x y
  for i in 0 1 2; do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    # 10# 防止 08 之类被当成八进制
    if (( 10#$x > 10#$y )); then echo 1; return; fi
    if (( 10#$x < 10#$y )); then echo -1; return; fi
  done
  echo 0
}

# 只在远端版本更高时安装，防止 GitHub 缓存导致降级；--force 无条件重装
cmd_update() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1
  local remote latest
  remote="$(curl -fsSL "$REPO_RAW/ccp")" || die "无法连接 GitHub，请检查网络"
  latest="$(printf '%s\n' "$remote" | sed -n 's/^CCP_VERSION="\(.*\)"$/\1/p' | head -1)"
  [[ "$latest" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "读不到远端版本号（${REPO_RAW}/ccp），已停止更新"
  if [[ $force -eq 1 ]]; then
    echo "强制重新安装：${CCP_VERSION} -> ${latest}"
  else
    case "$(ver_cmp "$latest" "$CCP_VERSION")" in
      0) echo "已是最新版本：$CCP_VERSION"; return 0 ;;
      -1) echo "本地版本 $CCP_VERSION 比远端 $latest 新（GitHub 下载链接可能还有几分钟缓存），已跳过"; return 0 ;;
    esac
    echo "更新：${CCP_VERSION} -> ${latest}"
  fi
  curl -fsSL "$REPO_RAW/install.sh" | CCP_REPO_RAW="$REPO_RAW" bash
}

usage() {
  cat <<EOF
ccp - Claude Code profile 管理器（一个 profile = 一个账号）

  ccp add <name>              创建 profile
  ccp login <name> [参数...]  登录该 profile 的账号（只打印链接，不自动开浏览器；name 可用 default）
  ccp run <name> [参数...]    用该 profile 启动 claude（参数原样传给 claude；name 可用 default）
  ccp take <from> <to> [参数...]  把 <from> 在当前项目最近的会话（跳过空会话）复制到 <to> 并接着运行
                              （--session <id> 指定会话；--force 覆盖 <to> 里更新的同名会话，
                               覆盖前备份为 .jsonl.bak；其余参数原样传给 claude；
                               from/to 可用 default，即直接运行 claude 时的账号）
  ccp sessions <name>         列出该账号在当前项目的会话（ID、时间、标题），配合 take --session 使用
  ccp list                    列出所有 profile 及登录账号
  ccp current                 显示当前 shell 使用的 profile
  ccp env <name>              输出环境变量，用于 eval "\$(ccp env <name>)"（name 可用 default）
  ccp share <name> [条目...]  从 ~/.claude 软链接共享配置（默认：${SHARE_ITEMS[*]}）
  ccp rm <name>               删除 profile（需确认）
  ccp update [--force]        更新 ccp 到最新版本（远端不比本地新时跳过；--force 强制重装）
  ccp version                 显示版本

profile 存放在：${ROOT}（可用 CCP_HOME 修改）
EOF
}

main() {
  local sub="${1:-help}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    add) cmd_add "$@" ;;
    login) cmd_login "$@" ;;
    run) cmd_run "$@" ;;
    take) cmd_take "$@" ;;
    sessions) cmd_sessions "$@" ;;
    list|ls) cmd_list ;;
    current) cmd_current ;;
    env) cmd_env "$@" ;;
    share) cmd_share "$@" ;;
    rm|remove) cmd_rm "$@" ;;
    update|upgrade) cmd_update "$@" ;;
    version|-v|--version) echo "ccp $CCP_VERSION" ;;
    help|-h|--help) usage ;;
    *) die "未知命令：${sub}（运行 ccp help 查看用法）" ;;
  esac
}

main "$@"
