#!/usr/bin/env bash
# ccp 发版脚本：改写 ccp / ccp.ps1 中的版本号 → 跑质量检查 → 提交并打 tag（不推送）。
# 用法：./release.sh <x.y.z>
set -euo pipefail

die() { echo "release: $*" >&2; exit 1; }

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

new="${1:-}"
[[ -n "$new" ]] || die "用法：./release.sh <x.y.z>"
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 x.y.z：'${new}'"

cur="$(sed -n 's/^CCP_VERSION="\(.*\)"$/\1/p' ccp | head -1)"
[[ -n "$cur" ]] || die "没在 ccp 中找到 CCP_VERSION"

# 逐段按数字比较，new 必须严格大于 cur（bash 3.2 兼容，不依赖 sort -V）
version_gt() {
  local IFS=.
  local a=($1) b=($2) i
  for i in 0 1 2; do
    (( 10#${a[i]} > 10#${b[i]} )) && return 0
    (( 10#${a[i]} < 10#${b[i]} )) && return 1
  done
  return 1
}
version_gt "$new" "$cur" || die "新版本 ${new} 必须大于当前版本 ${cur}"

[[ -z "$(git status --porcelain)" ]] || die "工作区不干净，请先提交或暂存改动"
if git rev-parse -q --verify "refs/tags/v${new}" >/dev/null; then
  die "tag v${new} 已存在"
fi

# 用 sed 写临时文件再 cat 回原文件：保留可执行权限；LC_ALL=C 按字节处理，ccp.ps1 的 BOM 原样保留
rewrite() {
  local file="$1" expr="$2" tmp
  tmp="$(mktemp)"
  LC_ALL=C sed "$expr" "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}
rewrite ccp "s/^CCP_VERSION=\"[^\"]*\"/CCP_VERSION=\"${new}\"/"
# 只匹配行首的赋值语句，避免改到 ccp update 里用来匹配远端版本的正则
rewrite ccp.ps1 "s/^\\\$CcpVersion = '[^']*'/\\\$CcpVersion = '${new}'/"

# 失败时还原两个文件，保持工作区干净
restore() { git checkout -- ccp ccp.ps1; }

grep -q "^CCP_VERSION=\"${new}\"$" ccp || { restore; die "ccp 版本号改写失败"; }
grep -q "^\\\$CcpVersion = '${new}'" ccp.ps1 || { restore; die "ccp.ps1 版本号改写失败"; }
# 每个文件应只改动一行
changed="$(git diff --numstat -- ccp ccp.ps1 | awk '{print $1 "/" $2}' | tr '\n' ' ')"
[[ "$changed" == "1/1 1/1 " ]] || { restore; die "版本号改写影响了意外的行（${changed}），已还原"; }
echo "版本号：${cur} → ${new}"

if ! bash scripts/check.sh; then
  restore
  die "质量检查未通过，已还原版本号改动"
fi

git add ccp ccp.ps1
git commit -q -m "Release v${new}"
git tag "v${new}"
echo
echo "已提交并打 tag v${new}（未推送）。确认无误后执行："
echo "  git push && git push --tags"
