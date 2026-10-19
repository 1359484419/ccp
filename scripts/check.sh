#!/usr/bin/env bash
# ccp 质量检查（macOS 自带 bash 3.2 / Linux / GitHub Actions 通用）。
# 用法：bash scripts/check.sh   任何一项失败则以非 0 退出；缺少可选工具（shellcheck / pwsh）时跳过。
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

failed=0
pass() { echo "  [通过] $*"; }
fail() { echo "  [失败] $*"; failed=1; }
skip() { echo "  [跳过] $*"; }
section() { echo; echo "== $* =="; }

# 列出存在的文件（bash 3.2 没有 mapfile，用 nullglob 展开后逐个判断）
existing() {
  local f
  for f in "$@"; do [[ -f "$f" ]] && echo "$f"; done
  return 0
}
shopt -s nullglob
BASH_FILES=($(existing ccp install.sh release.sh scripts/*.sh))
VAR_FILES=($(existing ccp install.sh release.sh scripts/*.sh tests/*.sh))
PS1_FILES=(*.ps1 scripts/*.ps1 tests/*.ps1)
shopt -u nullglob

section "bash -n 语法检查"
for f in "${BASH_FILES[@]}"; do
  if out="$(bash -n "$f" 2>&1)"; then pass "$f"; else fail "${f}：${out}"; fi
done

# bash 3.2 会把紧跟在 $var 后的中文字符算进变量名，必须写成 ${var}
section "中文变量写法检查（\$var 后不能紧跟非 ASCII 字符）"
for f in "${VAR_FILES[@]}"; do
  if out="$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$f")"; then
    fail "${f}：以下行需改成 \${var} 写法"
    echo "$out" | sed 's/^/      /'
  else
    pass "$f"
  fi
done

section "版本号一致性"
sh_ver="$(sed -n 's/^CCP_VERSION="\(.*\)"$/\1/p' ccp | head -1)"
ps_ver="$(LC_ALL=C sed -n "s/^\\\$CcpVersion = '\([^']*\)'.*$/\1/p" ccp.ps1 | head -1)"
if [[ -z "$sh_ver" || -z "$ps_ver" ]]; then
  fail "没读到版本号（ccp：'${sh_ver}'，ccp.ps1：'${ps_ver}'）"
elif [[ "$sh_ver" == "$ps_ver" ]]; then
  pass "ccp 与 ccp.ps1 均为 ${sh_ver}"
else
  fail "ccp 为 ${sh_ver}，ccp.ps1 为 ${ps_ver}"
fi

section "编码与换行"
# 按文件执行的 .ps1 需要恰好一个 BOM：Windows PowerShell 5.1 不带 BOM 时会按系统代码页读取，中文会乱码。
# install.ps1 例外，必须不带 BOM：irm | iex 会把 BOM 当成命令名报错（install.cmd 用 UTF-8 显式读取它）。
for f in "${PS1_FILES[@]}"; do
  head6="$(head -c 6 "$f" | od -An -tx1 | tr -d ' \n')"
  if [[ "$(basename "$f")" == "install.ps1" ]]; then
    if [[ "$head6" == efbbbf* ]]; then
      fail "${f} 不能带 BOM（irm | iex 会报错）"
    else
      pass "${f} 无 BOM"
    fi
  elif [[ "$head6" == "efbbbfefbbbf" ]]; then
    fail "${f} 有两个 BOM"
  elif [[ "$head6" == efbbbf* ]]; then
    pass "${f} 带 UTF-8 BOM"
  else
    fail "${f} 缺少 UTF-8 BOM"
  fi
done
if [[ -f install.cmd ]]; then
  # 每行都要以 \r 结尾，且文件以 \n 结束（最后一行也是完整的 CRLF）
  bad="$(LC_ALL=C grep -nv $'\r$' install.cmd | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')"
  if [[ -n "$bad" ]]; then
    fail "install.cmd 以下行不是 CRLF：${bad}"
  elif [[ "$(tail -c 1 install.cmd | od -An -tx1 | tr -d ' \n')" != "0a" ]]; then
    fail "install.cmd 最后一行缺少 CRLF"
  else
    pass "install.cmd 全部为 CRLF"
  fi
else
  fail "缺少 install.cmd"
fi

section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  for f in "${VAR_FILES[@]}"; do
    if out="$(shellcheck -S error "$f" 2>&1)"; then pass "$f"; else fail "$f"; echo "$out" | sed 's/^/      /'; fi
  done
else
  skip "未安装 shellcheck"
fi

section "PowerShell 语法解析"
if command -v pwsh >/dev/null 2>&1; then
  for f in "${PS1_FILES[@]}"; do
    # 路径通过环境变量传入，避免引号转义问题
    if out="$(CHECK_PS1="$f" pwsh -NoProfile -NonInteractive -Command '
      $errs = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $env:CHECK_PS1).Path, [ref]$null, [ref]$errs)
      if ($errs.Count -gt 0) { $errs | ForEach-Object { "第 $($_.Extent.StartLineNumber) 行：$($_.Message)" }; exit 1 }
    ' 2>&1)"; then
      pass "$f"
    else
      fail "$f"; echo "$out" | sed 's/^/      /'
    fi
  done
else
  skip "未安装 pwsh"
fi

section "冒烟测试"
if [[ -f tests/smoke.sh ]]; then
  if bash tests/smoke.sh; then pass "tests/smoke.sh"; else fail "tests/smoke.sh"; fi
else
  skip "没有 tests/smoke.sh"
fi

echo
if [[ $failed == 0 ]]; then
  echo "全部检查通过"
else
  echo "检查未通过，请修复上面标记为 [失败] 的项"
fi
exit "$failed"
