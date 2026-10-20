#!/usr/bin/env bash
# ccp（bash 版）冒烟测试：macOS 自带 bash 3.2 / Linux 通用，不访问网络。
# 用法：bash tests/smoke.sh   任一断言失败则以非 0 退出。
# 全部在临时目录里跑：临时 HOME + 假 claude（打印收到的 CLAUDE_CONFIG_DIR / BROWSER / 参数），
# 绝不碰真实的 ~/.claude、~/.claude.json、~/.claude-profiles。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CCP="$REPO/ccp"

T="$(mktemp -d "${TMPDIR:-/tmp}/ccp-smoke.XXXXXX")" || { echo "无法创建临时目录"; exit 1; }
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

# ---------- 隔离环境 ----------
unset CLAUDE_CONFIG_DIR CCP_HOME CCP_PROFILE BROWSER CCP_REPO_RAW
export HOME="$T/home"
export SHELL=/bin/bash
mkdir -p "$HOME" "$T/bin" "$T/proj" "$T/remote"
# 把安装目录放进 PATH，install.sh 就不会去改 rc 文件
export PATH="$T/bin:$HOME/.local/bin:$PATH"
ROOT="$HOME/.claude-profiles"
PROJ="$T/proj"

# 假 claude：把收到的环境和参数打印出来
cat > "$T/bin/claude" <<'FAKE'
#!/bin/sh
echo "FAKE_CFG=${CLAUDE_CONFIG_DIR-__UNSET__}"
echo "FAKE_PROFILE=${CCP_PROFILE-__UNSET__}"
echo "FAKE_BROWSER=${BROWSER-__UNSET__}"
echo "FAKE_ARGS=$*"
FAKE
chmod +x "$T/bin/claude"

# ---------- 断言工具 ----------
failed=0; total=0
pass() { total=$((total+1)); echo "PASS: $*"; }
fail() { total=$((total+1)); failed=$((failed+1)); echo "FAIL: $*"; }
# r [VAR=值...] <命令...>：在项目目录下运行，输出存进 OUT，退出码存进 RC
r() { OUT="$(cd "$PROJ" && env "$@" 2>&1 </dev/null)"; RC=$?; }
# ri <输入> [VAR=值...] <命令...>：同上，但从 stdin 喂入一行
ri() { local in="$1"; shift; OUT="$(cd "$PROJ" && printf '%s\n' "$in" | env "$@" 2>&1)"; RC=$?; }
show() { echo "$OUT" | sed 's/^/      | /'; }
has()   { if [[ "$OUT" == *"$2"* ]]; then pass "$1"; else fail "${1}（输出里没有：$2）"; show; fi; }
lacks() { if [[ "$OUT" != *"$2"* ]]; then pass "$1"; else fail "${1}（输出里不该有：$2）"; show; fi; }
rc_is() { if [[ "$RC" == "$2" ]]; then pass "$1"; else fail "${1}（退出码 ${RC}，期望 $2）"; show; fi; }
ok()    { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
same()  { cmp -s "$1" "$2"; }
content_is() { [[ "$(cat "$1" 2>/dev/null)" == "$2" ]]; }

FALSE_BIN=/usr/bin/false; [[ -x "$FALSE_BIN" ]] || FALSE_BIN=/bin/false
LOCAL_VER="$(sed -n 's/^CCP_VERSION="\(.*\)"$/\1/p' "$CCP" | head -1)"

echo "== version / help =="
r "$CCP" version;   has "version 输出" "ccp $LOCAL_VER"; rc_is "version 退出码 0" 0
ok "版本号格式为 x.y.z" [ -n "$(echo "$LOCAL_VER" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$')" ]
r "$CCP" --version; has "--version 输出" "ccp $LOCAL_VER"
r "$CCP" -v;        has "-v 输出" "ccp $LOCAL_VER"
r "$CCP" help
has "help 列出 take --force" "--force"
has "help 列出 update [--force]" "ccp update [--force]"
has "help 说明 login 可用 default" "不自动开浏览器；name 可用 default"
has "help 说明 env 可用 default" "ccp env <name>              输出环境变量，用于 eval \"\$(ccp env <name>)\"（name 可用 default）"
r "$CCP";           has "无参数显示帮助" "ccp add <name>"
r "$CCP" bogus;     rc_is "未知命令退出 1" 1; has "未知命令提示" "未知命令"

echo "== add / list / current =="
r "$CCP" list;      has "空列表提示" "还没有 profile"
r "$CCP" add a;     rc_is "add a" 0; ok "a 目录已创建" [ -d "$ROOT/a" ]
r "$CCP" add a;     has "重复 add 幂等" "已存在"
r "$CCP" add b;     ok "b 目录已创建" [ -d "$ROOT/b" ]
r "$CCP" add default;  rc_is "add default 被拒" 1
r "$CCP" add 'x y';    rc_is "非法名字被拒" 1
r CCP_HOME="$T/alt" "$CCP" add x; ok "CCP_HOME 覆盖存放位置" [ -d "$T/alt/x" ]
printf '{\n  "oauthAccount": {\n    "emailAddress": "a@example.com"\n  }\n}\n' > "$ROOT/a/.claude.json"
printf '{"oauthAccount":{"emailAddress":"def@example.com"}}\n' > "$HOME/.claude.json"
r "$CCP" list
has "list 显示 a 的邮箱" "a@example.com"
has "list 显示 b 未登录" "（未登录）"
has "list 显示 default" "def@example.com"
r CLAUDE_CONFIG_DIR="$ROOT/a" "$CCP" list
if echo "$OUT" | grep -qE '^\* +a +a@example.com'; then pass "list 标记当前 profile"; else fail "list 标记当前 profile"; show; fi
r CLAUDE_CONFIG_DIR="$ROOT/a" "$CCP" current; has "current 显示 profile 与邮箱" "a  ($ROOT/a)  a@example.com"
r "$CCP" current;   has "current 显示 default" "(default)  ($HOME/.claude)  def@example.com"

echo "== run =="
r "$CCP" run a --model x -p "hi there"
has "run 设置 CLAUDE_CONFIG_DIR" "FAKE_CFG=$ROOT/a"
has "run 设置 CCP_PROFILE" "FAKE_PROFILE=a"
has "run 透传参数" "FAKE_ARGS=--model x -p hi there"
r CLAUDE_CONFIG_DIR=/x "$CCP" run default --foo
has "run default 清掉 CLAUDE_CONFIG_DIR" "FAKE_CFG=__UNSET__"
has "run default 透传参数" "FAKE_ARGS=--foo"
r "$CCP" run nope;  rc_is "run 不存在的 profile 退出 1" 1; lacks "run 不存在的 profile 不启动 claude" "FAKE_ARGS"

echo "== login [C] =="
r CLAUDE_CONFIG_DIR=/x "$CCP" login default --foo
rc_is "login default 退出码 0" 0
has "login default 清掉 CLAUDE_CONFIG_DIR" "FAKE_CFG=__UNSET__"
has "login default 设 CCP_PROFILE" "FAKE_PROFILE=default"
has "login default 默认不开浏览器" "FAKE_BROWSER=$FALSE_BIN"
has "login default 参数" "FAKE_ARGS=auth login --foo"
r BROWSER=mybrowser "$CCP" login default
has "login default 尊重用户的 BROWSER" "FAKE_BROWSER=mybrowser"
r "$CCP" login a
has "login a 设置 CLAUDE_CONFIG_DIR" "FAKE_CFG=$ROOT/a"
has "login a 默认不开浏览器" "FAKE_BROWSER=$FALSE_BIN"
has "login a 参数" "FAKE_ARGS=auth login"
r BROWSER=mybrowser "$CCP" login a; has "login a 尊重用户的 BROWSER" "FAKE_BROWSER=mybrowser"
r "$CCP" login nope; rc_is "login 不存在的 profile 退出 1" 1

echo "== env [C] =="
r "$CCP" env default
ok "env default 输出" [ "$OUT" == $'unset CLAUDE_CONFIG_DIR\nexport CCP_PROFILE=default' ]
OUT="$(CLAUDE_CONFIG_DIR=/x; eval "$("$CCP" env default)"; echo "${CLAUDE_CONFIG_DIR-__UNSET__}|${CCP_PROFILE:-}")"
ok "eval env default 后变量正确" [ "$OUT" == "__UNSET__|default" ]
OUT="$(eval "$("$CCP" env a)"; echo "${CLAUDE_CONFIG_DIR}|${CCP_PROFILE}")"
ok "eval env a 后变量正确" [ "$OUT" == "$ROOT/a|a" ]
r "$CCP" env nope;  rc_is "env 不存在的 profile 退出 1" 1

echo "== share =="
mkdir -p "$HOME/.claude/skills"; echo "global" > "$HOME/.claude/CLAUDE.md"
echo "own" > "$ROOT/b/CLAUDE.md"
r "$CCP" share a
ok "share 链接 CLAUDE.md" [ -L "$ROOT/a/CLAUDE.md" ]
ok "share 链接 skills" [ -L "$ROOT/a/skills" ]
has "share 跳过不存在的条目" "跳过 commands"
r "$CCP" share a;   has "share 重复执行幂等" "已链接 CLAUDE.md"
r "$CCP" share b CLAUDE.md; has "share 不覆盖 profile 自有文件" "已存在"
ok "b 自有 CLAUDE.md 未被改动" content_is "$ROOT/b/CLAUDE.md" own
r "$CCP" share a .credentials.json; has "share 拒绝凭证" "不能共享"
r "$CCP" share default; rc_is "share default 被拒" 1; has "share default 提示保留名" "保留名"

echo "== rm [C] =="
r "$CCP" rm default; rc_is "rm default 被拒" 1; has "rm default 提示保留名" "保留名"
ok "rm default 后 ~/.claude 仍在" [ -d "$HOME/.claude" ]
r "$CCP" rm nope;   rc_is "rm 不存在的 profile 退出 0" 0; has "rm 不存在提示" "无需删除"
"$CCP" add c >/dev/null; ln -s "$HOME/.claude/skills" "$ROOT/c/skills"
ri n "$CCP" rm c;   has "rm 回答 n 取消" "已取消"; ok "取消后 c 仍在" [ -d "$ROOT/c" ]
r "$CCP" rm c;      rc_is "stdin 关闭时按取消处理（退出 0）" 0; has "stdin 关闭时提示已取消" "已取消"; ok "stdin 关闭时不删除" [ -d "$ROOT/c" ]
ri y "$CCP" rm c;   rc_is "rm 回答 y 退出 0" 0; ok "c 已删除" [ ! -e "$ROOT/c" ]
ok "rm 不跟随共享软链接" [ -d "$HOME/.claude/skills" ]

echo "== take [A] =="
KEY="$(cd "$PROJ" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
SA="$ROOT/a/projects/$KEY"; SB="$ROOT/b/projects/$KEY"
r "$CCP" take a b;  rc_is "来源没有会话时退出 1" 1
mkdir -p "$SA/s2"
# 会话文件里要有 AI 回复，否则会被当成空会话跳过
printf 's1-a\n{"type":"assistant"}\n' > "$SA/s1.jsonl"; touch -t 202001010000 "$SA/s1.jsonl"
printf 's2-a\n{"type":"assistant"}\n' > "$SA/s2.jsonl"; touch -t 202001020000 "$SA/s2.jsonl"
echo "sub" > "$SA/s2/sub.txt"
r "$CCP" take a a;  rc_is "from == to 退出 1" 1
r "$CCP" take a nope; rc_is "目标不存在退出 1" 1
r "$CCP" take a b;  rc_is "take 基本调用退出 0" 0

# 1. 首次复制：取最近的会话，附属目录一并复制，claude 参数透传
rm -rf "$ROOT/b/projects"
r "$CCP" take a b -p hi
rc_is "首次 take 退出 0" 0
ok "首次 take 复制最近会话" same "$SA/s2.jsonl" "$SB/s2.jsonl"
ok "首次 take 不复制旧会话" [ ! -e "$SB/s1.jsonl" ]
ok "首次 take 复制附属目录" content_is "$SB/s2/sub.txt" sub
has "首次 take 用 <to> 运行" "FAKE_CFG=$ROOT/b"
has "首次 take resume 并透传参数" "FAKE_ARGS=--resume s2 -p hi"

# 2. 内容相同：不复制、不备份，直接 resume
touch -t 201901010000 "$SB/s2.jsonl"
r "$CCP" take a b
rc_is "内容相同退出 0" 0
has "内容相同提示已是最新" "已是最新"
ok "内容相同不生成备份" [ ! -e "$SB/s2.jsonl.bak" ]
has "内容相同直接 resume" "FAKE_ARGS=--resume s2"
touch -t 201901020000 "$T/ref"
ok "内容相同不重新复制（mtime 未变）" [ ! "$SB/s2.jsonl" -nt "$T/ref" ]

# 3. 目标更新且未加 --force：拒绝，目标不变
echo "s2-b-progress" > "$SB/s2.jsonl"; touch -t 202101010000 "$SB/s2.jsonl"
r "$CCP" take a b
rc_is "目标更新时拒绝（退出 1）" 1
has "目标更新时的提示" "'b' 里的会话 s2 比 'a' 的更新（可能已在 'b' 上继续过），为避免覆盖进度已停止；确认覆盖请加 --force"
ok "拒绝时目标未被改动" content_is "$SB/s2.jsonl" s2-b-progress
ok "拒绝时不生成备份" [ ! -e "$SB/s2.jsonl.bak" ]
lacks "拒绝时不启动 claude" "FAKE_ARGS"

# 4. 第一个不认识的参数之后都是 claude 参数：--model 之后的 --force 不生效
r "$CCP" take a b --model m --force
rc_is "claude 参数后的 --force 不算 ccp 选项" 1
ok "仍未改动目标" content_is "$SB/s2.jsonl" s2-b-progress

# 5. --force --session：先备份再覆盖
r "$CCP" take a b --force --session s2 --model x
rc_is "--force --session 退出 0" 0
ok "--force 生成备份且内容为旧目标" content_is "$SB/s2.jsonl.bak" s2-b-progress
ok "--force 覆盖为来源内容" same "$SA/s2.jsonl" "$SB/s2.jsonl"
has "--force 提示备份位置" "$SB/s2.jsonl.bak"
has "--force 透传参数" "FAKE_ARGS=--resume s2 --model x"

# 6. 选项顺序反过来：--session s1 --force
echo "s1-b-progress" > "$SB/s1.jsonl"; touch -t 202101010000 "$SB/s1.jsonl"
r "$CCP" take a b --session s1 --force -p hi
rc_is "--session --force 退出 0" 0
ok "--session 指定会话被复制" same "$SA/s1.jsonl" "$SB/s1.jsonl"
ok "--session --force 生成备份" content_is "$SB/s1.jsonl.bak" s1-b-progress
has "--session --force 透传参数" "FAKE_ARGS=--resume s1 -p hi"

# 7. 来源更新（未加 --force）：备份（覆盖旧备份）后复制
echo "s2-b-old" > "$SB/s2.jsonl"; touch -t 201901010000 "$SB/s2.jsonl"
echo "stale" > "$SB/s2.jsonl.bak"
echo "s2-a-more" >> "$SA/s2.jsonl"; touch -t 202001030000 "$SA/s2.jsonl"
r "$CCP" take a b
rc_is "来源更新退出 0" 0
ok "来源更新时覆盖旧备份" content_is "$SB/s2.jsonl.bak" s2-b-old
ok "来源更新时复制新内容" same "$SA/s2.jsonl" "$SB/s2.jsonl"
has "来源更新提示备份位置" "已备份到：$SB/s2.jsonl.bak"

# 8. 参数错误
r "$CCP" take a b --session;      rc_is "--session 缺值退出 1" 1; lacks "--session 缺值不启动 claude" "FAKE_ARGS"
r "$CCP" take a b --session nope; rc_is "--session 会话不存在退出 1" 1
r "$CCP" take a b --session ../../x; rc_is "--session 路径穿越被拒绝" 1; has "--session 路径穿越提示格式错误" "会话 ID 格式不对"
r "$CCP" take a;                  rc_is "take 参数不足退出 1" 1

# 9. default 作为 <to> / <from>
DK="$HOME/.claude/projects/$KEY"
r CLAUDE_CONFIG_DIR=/x "$CCP" take a default
rc_is "take a default 退出 0" 0
has "take 到 default 不设 CLAUDE_CONFIG_DIR" "FAKE_CFG=__UNSET__"
ok "会话复制到 ~/.claude/projects" same "$SA/s2.jsonl" "$DK/s2.jsonl"
mkdir -p "$DK"; printf 'd1\n{"type":"assistant"}\n' > "$DK/d1.jsonl"; touch -t 203001010000 "$DK/d1.jsonl"
r "$CCP" take default b
ok "take default b 复制 default 的最新会话" same "$DK/d1.jsonl" "$SB/d1.jsonl"
has "take default b 用 b 运行" "FAKE_CFG=$ROOT/b"

# 10. 跳过空会话（只打开过 claude 或只执行过 /clear 的会话没有 AI 回复），显示会话标题
echo '{"type":"ai-title","aiTitle":"修复登录","sessionId":"s2"}' >> "$SA/s2.jsonl"; touch -t 202001030000 "$SA/s2.jsonl"
echo '{"type":"last-prompt","lastPrompt":"/clear","sessionId":"e1"}' > "$SA/e1.jsonl"; touch -t 203501010000 "$SA/e1.jsonl"
rm -rf "$ROOT/b/projects"
r "$CCP" take a b
rc_is "有更新的空会话时 take 退出 0" 0
has "提示跳过了空会话" "已跳过 1 个更新但没有对话内容的会话"
has "跳过空会话后 resume 有对话的会话" "FAKE_ARGS=--resume s2"
ok "空会话没有被复制" [ ! -e "$SB/e1.jsonl" ]
has "take 显示会话标题" "会话：s2  "
has "take 显示 aiTitle" "修复登录"
r "$CCP" take a b --session e1 --force
rc_is "--session 可以明确指定空会话" 0; has "--session 指定空会话时照样 resume" "FAKE_ARGS=--resume e1"
r "$CCP" sessions a
rc_is "sessions 退出 0" 0
has "sessions 列出有对话的会话" "s2  "
has "sessions 显示标题" "修复登录"
lacks "sessions 不列出空会话" "e1  "
has "sessions 提示空会话数量" "另有 1 个没有对话内容的会话未列出"
r "$CCP" sessions;   rc_is "sessions 缺参数退出 1" 1
r "$CCP" sessions nope; rc_is "sessions 不存在的 profile 退出 1" 1
"$CCP" add e >/dev/null 2>&1; mkdir -p "$ROOT/e/projects/$KEY"; cp "$SA/e1.jsonl" "$ROOT/e/projects/$KEY/"
r "$CCP" take e b
rc_is "只有空会话时 take 退出 1" 1
has "只有空会话时的提示" "没有包含对话的会话"
lacks "只有空会话时不启动 claude" "FAKE_ARGS"

echo "== update [B] =="
IFS=. read -r V1 V2 V3 <<< "$LOCAL_VER"
HIGH="${V1}.$((V2+10)).0"          # 数字更大，但按字符串比较会更小（如 1.14.0 vs 1.4.0）
HIGH_PATCH="${V1}.${V2}.$((V3+1))"
PADDED="${V1}.0${V2}.${V3}"        # 与本地相等（带前导 0，检查不会按八进制解析）
if (( V3 > 0 )); then LOW="${V1}.${V2}.$((V3-1))"; elif (( V2 > 0 )); then LOW="${V1}.$((V2-1)).99"; else LOW="$((V1-1)).99.99"; fi
cp "$REPO/install.sh" "$T/remote/install.sh"
INST="$HOME/.local/bin/ccp"
# remote <版本号|NONE>：生成远端 ccp
remote() {
  if [[ "$1" == NONE ]]; then
    sed '/^CCP_VERSION=/d' "$CCP" > "$T/remote/ccp"
  else
    sed "s/^CCP_VERSION=.*/CCP_VERSION=\"$1\"/" "$CCP" > "$T/remote/ccp"
  fi
  rm -f "$INST"
}
installed_ver() { sed -n 's/^CCP_VERSION="\(.*\)"$/\1/p' "$INST" 2>/dev/null | head -1; }
U=(CCP_REPO_RAW="file://$T/remote" "$CCP" update)

remote "$HIGH"; r "${U[@]}"
rc_is "远端更新时退出 0" 0
has "远端更新提示" "更新：${LOCAL_VER} -> ${HIGH}"
ok "按数字比较并安装远端版本" [ "$(installed_ver)" == "$HIGH" ]
remote "$HIGH_PATCH"; r "${U[@]}"
ok "补丁号更高也更新" [ "$(installed_ver)" == "$HIGH_PATCH" ]
remote "$LOCAL_VER"; r "${U[@]}"
rc_is "相同版本退出 0" 0; has "相同版本提示" "已是最新版本"; ok "相同版本不安装" [ ! -e "$INST" ]
remote "$PADDED"; r "${U[@]}"
has "带前导 0 的相同版本视为相等" "已是最新版本"; ok "带前导 0 不安装" [ ! -e "$INST" ]
remote "$LOW"; r "${U[@]}"
rc_is "远端更旧退出 0" 0
has "远端更旧提示跳过" "本地版本 ${LOCAL_VER} 比远端 ${LOW} 新（GitHub 下载链接可能还有几分钟缓存），已跳过"
ok "远端更旧不安装" [ ! -e "$INST" ]
remote "$LOW"; r "${U[@]}" --force
rc_is "--force 退出 0" 0
ok "--force 强制安装更旧版本" [ "$(installed_ver)" == "$LOW" ]
remote "$LOCAL_VER"; r "${U[@]}" --force
ok "--force 重装相同版本" [ "$(installed_ver)" == "$LOCAL_VER" ]
remote NONE; r "${U[@]}"
rc_is "读不到远端版本号退出 1" 1; has "读不到版本号提示" "读不到远端版本号"; ok "读不到版本号不安装" [ ! -e "$INST" ]
remote NONE; r "${U[@]}" --force
rc_is "读不到版本号时 --force 也不安装" 1; ok "读不到版本号 --force 不安装" [ ! -e "$INST" ]
remote "abc"; r "${U[@]}"
rc_is "版本号格式不对退出 1" 1
rm -f "$T/remote/ccp"; r "${U[@]}"
rc_is "远端文件不存在退出 1" 1; ok "远端不存在不安装" [ ! -e "$INST" ]

echo "== 真实目录未被触碰 =="
ok "测试 HOME 在临时目录内" [ "${HOME#"$T"}" != "$HOME" ]

echo
echo "共 ${total} 项，失败 ${failed} 项"
[[ $failed -eq 0 ]]
