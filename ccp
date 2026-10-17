#!/usr/bin/env bash
# ccp - Claude Code profile 管理器（macOS / Linux）
# 每个 profile 是一个独立的 CLAUDE_CONFIG_DIR，对应一个账号，登录态/会话/设置互相隔离。
set -euo pipefail

CCP_VERSION="1.3.0"
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
  require_profile "$1"
  local d; d="$(profile_dir "$1")"; shift
  command -v claude >/dev/null || die "找不到 claude 命令，请先安装 Claude Code"
  if [[ -z "${BROWSER:-}" ]]; then
    local f; for f in /usr/bin/false /bin/false; do [[ -x "$f" ]] && break; done
    export BROWSER="$f"
  fi
  echo "请复制下面打印的链接到浏览器打开，登录后把授权码粘贴回来"
  CLAUDE_CONFIG_DIR="$d" CCP_PROFILE="${d##*/}" exec claude auth login "$@"
}

# Claude Code 按项目路径存会话：路径中字母数字以外的字符都换成 -
project_key() { printf '%s' "$(pwd -P)" | sed 's/[^A-Za-z0-9]/-/g'; }

# 把 <from> 在当前项目下最近的（或指定的）会话复制到 <to>，然后用 <to> 接着这个会话
cmd_take() {
  [[ $# -ge 2 ]] || die "用法：ccp take <from> <to> [--session <id>] [claude 参数...]"
  config_dir_of "$1" >/dev/null; config_dir_of "$2" >/dev/null
  [[ "$1" != "$2" ]] || die "<from> 和 <to> 不能相同"
  local from="$1" to="$2"; shift 2
  local sid=""
  if [[ "${1:-}" == "--session" ]]; then
    [[ -n "${2:-}" ]] || die "--session 后面需要会话 ID"
    sid="$2"; shift 2
  fi
  local key; key="$(project_key)"
  local src_dir dst_dir
  src_dir="$(config_dir_of "$from")/projects/$key"
  dst_dir="$(config_dir_of "$to")/projects/$key"
  [[ -d "$src_dir" ]] || die "'$from' 在当前目录（${PWD}）下没有会话"
  if [[ -z "$sid" ]]; then
    local latest; latest="$(ls -t "$src_dir"/*.jsonl 2>/dev/null | head -1)"
    [[ -n "$latest" ]] || die "'$from' 在当前目录下没有会话"
    sid="$(basename "$latest" .jsonl)"
  fi
  [[ -f "$src_dir/$sid.jsonl" ]] || die "'$from' 在当前目录下找不到会话 $sid"
  mkdir -p "$dst_dir"
  cp "$src_dir/$sid.jsonl" "$dst_dir/"
  # 部分版本会把子代理等记录放在同名目录里，一并复制
  [[ -d "$src_dir/$sid" ]] && cp -R "$src_dir/$sid" "$dst_dir/"
  echo "已把 '$from' 的会话 $sid 复制到 '$to'，正在接着运行…"
  cmd_run "$to" --resume "$sid" "$@"
}

cmd_env() {
  [[ $# -ge 1 ]] || die "用法：eval \"\$(ccp env <name>)\""
  require_profile "$1"
  printf 'export CLAUDE_CONFIG_DIR=%q\nexport CCP_PROFILE=%q\n' "$(profile_dir "$1")" "$1"
}

cmd_share() {
  [[ $# -ge 1 ]] || die "用法：ccp share <name> [条目...]   默认：${SHARE_ITEMS[*]}"
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
  local d; d="$(profile_dir "$1")"
  [[ -d "$d" ]] || { echo "profile '$1' 不存在，无需删除"; return 0; }
  local acct; acct="$(account_of "$d")"
  read -r -p "删除 profile '$1'（${acct:-未登录}），包括其会话历史？[y/N] " ans
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

cmd_update() {
  local latest
  latest="$(curl -fsSL "$REPO_RAW/ccp" | sed -n 's/^CCP_VERSION="\(.*\)"$/\1/p' | head -1)" || die "无法连接 GitHub，请检查网络"
  if [[ -n "$latest" && "$latest" == "$CCP_VERSION" ]]; then
    echo "已是最新版本：$CCP_VERSION"
    return 0
  fi
  echo "更新：${CCP_VERSION} -> ${latest:-最新版}"
  curl -fsSL "$REPO_RAW/install.sh" | bash
}

usage() {
  cat <<EOF
ccp - Claude Code profile 管理器（一个 profile = 一个账号）

  ccp add <name>              创建 profile
  ccp login <name> [参数...]  登录该 profile 的账号（只打印链接，不自动开浏览器）
  ccp run <name> [参数...]    用该 profile 启动 claude（参数原样传给 claude；name 可用 default）
  ccp take <from> <to> [参数...]  把 <from> 在当前项目最近的会话复制到 <to> 并接着运行
                              （--session <id> 指定会话；其余参数原样传给 claude；
                               from/to 可用 default，即直接运行 claude 时的账号）
  ccp list                    列出所有 profile 及登录账号
  ccp current                 显示当前 shell 使用的 profile
  ccp env <name>              输出环境变量，用于 eval "\$(ccp env <name>)"
  ccp share <name> [条目...]  从 ~/.claude 软链接共享配置（默认：${SHARE_ITEMS[*]}）
  ccp rm <name>               删除 profile（需确认）
  ccp update                  更新 ccp 到最新版本
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
    list|ls) cmd_list ;;
    current) cmd_current ;;
    env) cmd_env "$@" ;;
    share) cmd_share "$@" ;;
    rm|remove) cmd_rm "$@" ;;
    update|upgrade) cmd_update ;;
    version|-v|--version) echo "ccp $CCP_VERSION" ;;
    help|-h|--help) usage ;;
    *) die "未知命令：${sub}（运行 ccp help 查看用法）" ;;
  esac
}

main "$@"
