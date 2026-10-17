#!/usr/bin/env bash
# ccp 安装脚本（macOS / Linux）。可重复运行：已安装则覆盖为最新版本，PATH 只添加一次。
# 在线安装：curl -fsSL https://raw.githubusercontent.com/1359484419/ccp/main/install.sh | bash
# 本地安装：bash install.sh（在 ccp 所在目录）
set -euo pipefail

# 整体包在函数里：curl 下载中断时不会执行半截脚本
main() {
  local repo_raw="${CCP_REPO_RAW:-https://raw.githubusercontent.com/1359484419/ccp/main}"
  local bin_dir="$HOME/.local/bin"
  local mark="# added by ccp installer"
  local src_dir="" rc need_reload=0

  # 本地运行时 BASH_SOURCE 指向脚本文件；通过管道运行时为空，改为在线下载
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  mkdir -p "$bin_dir"
  if [[ -n "$src_dir" && -f "$src_dir/ccp" ]]; then
    cp "$src_dir/ccp" "$bin_dir/ccp.tmp"
  else
    echo "下载 ccp：${repo_raw}/ccp"
    curl -fsSL "$repo_raw/ccp" -o "$bin_dir/ccp.tmp"
  fi
  # 先下载到临时文件，成功后再替换，避免中断时留下损坏的 ccp
  chmod +x "$bin_dir/ccp.tmp"
  mv "$bin_dir/ccp.tmp" "$bin_dir/ccp"
  echo "已安装：$bin_dir/ccp"

  # 按登录 shell 选择配置文件
  case "$(basename "${SHELL:-}")" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) if [[ "$(uname)" == "Darwin" ]]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *)    rc="$HOME/.profile" ;;
  esac

  case ":$PATH:" in
    *":$bin_dir:"*) echo "PATH 已包含 $bin_dir" ;;
    *)
      if [[ -f "$rc" ]] && grep -qF "$mark" "$rc"; then
        echo "${rc} 已配置过 PATH"
      else
        printf '\n%s\nexport PATH="$HOME/.local/bin:$PATH"\n' "$mark" >> "$rc"
        echo "已把 $bin_dir 加入 PATH（写入 ${rc}）"
      fi
      need_reload=1
      ;;
  esac

  command -v claude >/dev/null || echo "注意：没找到 claude 命令，请先安装 Claude Code"

  echo
  if [[ $need_reload == 1 ]]; then
    echo "安装完成。请重开终端，或执行：source $rc"
  else
    echo "安装完成。"
  fi
  echo "开始使用：ccp add work && ccp login work && ccp run work"
}

main "$@"
