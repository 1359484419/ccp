# ccp — Claude Code 多 profile 管理

一个 profile 对应一个账号：每个 profile 是独立的 `CLAUDE_CONFIG_DIR`，登录态、会话历史和设置互相隔离。
适用于同一个人在不同身份间切换，比如个人号和公司号、不同组织的账号。

> 不包含检测到额度用完就自动换号、跨账号搬运会话这类功能。用多个账号叠加额度违反 Anthropic 条款，有封号风险。额度不够请升级 Max / Team 或开启 extra usage。

## 安装

**macOS / Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/1359484419/ccp/main/install.sh | bash
```

**Windows（PowerShell）**
```powershell
irm https://raw.githubusercontent.com/1359484419/ccp/main/install.ps1 | iex
```

装完重开终端（或 PowerShell 窗口）即可使用。

<details><summary>无法访问 GitHub 时：离线安装</summary>

下载或拿到本仓库的 zip 包后解压，mac/Linux 在目录中运行 `bash install.sh`，Windows 双击 `install.cmd`。
</details>

**升级**：运行 `ccp update` 即可。1.1.0 之前的旧版本（包括 zip 离线安装的）没有这个命令，需要再运行一次上面的安装命令，会原地覆盖，已登录的 profile 不受影响。之后就可以用 `ccp update` 了。用 `ccp version` 查看当前版本。

安装脚本可以重复运行，安装内容如下：

| | macOS / Linux | Windows |
|---|---|---|
| 脚本位置 | `~/.local/bin/ccp` | `~\bin\ccp.ps1` |
| 注册命令 | 在 `~/.zshrc`（或 bash 配置）中把 `~/.local/bin` 加入 PATH | 在 PowerShell 5.1 和 7 的 `$PROFILE` 里各加一个 `ccp` 函数 |
| 其他 | — | 把当前用户的执行策略设为 `RemoteSigned` |

卸载：删除上面的脚本文件，再删掉配置文件中 `# added by ccp installer` 那两行。profile 数据在 `~/.claude-profiles`，不再需要的话可以手动删除。

## 使用

```bash
ccp add work            # 创建 profile
ccp login work          # 登录这个 profile 的账号（只需一次）
ccp run work            # 用 work 启动 claude
ccp share work          # 可选：共享 ~/.claude 的 CLAUDE.md / skills / commands / agents
ccp list                # 查看所有 profile 和对应账号
ccp run work --resume   # claude 的参数原样透传
ccp update              # 更新 ccp
```

**登录方式**：`ccp login` 默认不自动打开浏览器（相当于 `BROWSER=/usr/bin/false claude auth login`；Windows 上同样处理），所以没有浏览器的 Linux 服务器也能用。终端会打印一个登录链接，复制到任意设备的浏览器打开，登录后把授权码粘贴回终端。想让它自动打开浏览器的话，先自己设置 `BROWSER`，脚本不会覆盖。

同一个项目目录可以同时开两个终端，分别用 `ccp run a`、`ccp run b` 启动。如果两个会话会改同样的文件，建议先用 `git worktree` 分开工作目录。

**macOS/Linux 下把整个 shell 切到某个 profile**（对 IDE 插件等场景有用）：
```bash
eval "$(ccp env work)"   # 之后在这个 shell 里直接运行 claude 或 code . 都会用 work
```

直接运行 `claude`（不经过 ccp）时，仍然使用默认的 `~/.claude` 账号，不受影响。

## 说明
- profile 默认放在 `~/.claude-profiles/<name>`，可以通过环境变量 `CCP_HOME` 修改。
- `share` 只链接配置类条目。`.claude.json`、凭证、`projects`、`sessions` 会被拒绝共享。已存在的同名文件不会被覆盖，重复运行也不会出问题。
- `ccp login` 后面的参数会传给 `claude auth login`，例如 `--console`（用 API 计费账号）、`--sso`、`--email x@y.com`。
- 启动的 claude 进程会带上环境变量 `CCP_PROFILE=<name>`，可以在 statusline 里显示当前 profile。
- macOS 登录凭证存在钥匙串里，`ccp rm` 后可能需要在"钥匙串访问"里手动清理。
