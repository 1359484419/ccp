# ccp - Claude Code profile 管理器（Windows PowerShell 5.1+ / PowerShell 7）
# 每个 profile 是一个独立的 CLAUDE_CONFIG_DIR，对应一个账号，登录态/会话/设置互相隔离。
# 用法与 macOS 版一致：ccp add/run/list/current/share/rm

$ErrorActionPreference = 'Stop'

$CcpVersion = '1.3.0'
$RepoRaw = if ($env:CCP_REPO_RAW) { $env:CCP_REPO_RAW } else { 'https://raw.githubusercontent.com/1359484419/ccp/main' }
$Root = if ($env:CCP_HOME) { $env:CCP_HOME } else { Join-Path $HOME '.claude-profiles' }
$DefaultDir = Join-Path $HOME '.claude'
# share 子命令默认从 ~/.claude 共享的条目（不含凭证和账号状态）
$ShareItems = @('CLAUDE.md', 'skills', 'commands', 'agents')
$Forbidden = @('.claude.json', '.credentials.json', 'projects', 'sessions', 'history.jsonl')

function Fail($msg) { Write-Host "ccp: $msg" -ForegroundColor Red; exit 1 }

function Test-Name($name) {
    if ($name -notmatch '^[A-Za-z0-9_-]+$') { Fail "profile 名只能包含字母、数字、- 和 _：'$name'" }
}

function Get-ProfileDir($name) { Join-Path $Root $name }

function Assert-Profile($name) {
    Test-Name $name
    if (-not (Test-Path (Get-ProfileDir $name) -PathType Container)) { Fail "profile '$name' 不存在，先运行：ccp add $name" }
}

# 名字对应的配置目录；default 表示直接运行 claude 时用的 ~\.claude
function Get-ConfigDir($name) {
    if ($name -eq 'default') { return $DefaultDir }
    Assert-Profile $name
    return Get-ProfileDir $name
}

# 从 .claude.json 读出登录邮箱；未登录返回空
function Get-Account($dir) {
    $f = Join-Path $dir '.claude.json'
    if (-not (Test-Path $f)) { return '' }
    try {
        $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.oauthAccount -and $j.oauthAccount.emailAddress) { return $j.oauthAccount.emailAddress }
    } catch {}
    return ''
}

function Show-Usage {
    @"
ccp - Claude Code profile 管理器（一个 profile = 一个账号）

  ccp add <name>              创建 profile
  ccp login <name> [参数...]  登录该 profile 的账号（只打印链接，不自动开浏览器）
  ccp run <name> [参数...]    用该 profile 启动 claude（参数原样传给 claude；name 可用 default）
  ccp take <from> <to> [参数...]  把 <from> 在当前项目最近的会话复制到 <to> 并接着运行
                              （--session <id> 指定会话；其余参数原样传给 claude；
                               from/to 可用 default，即直接运行 claude 时的账号）
  ccp list                    列出所有 profile 及登录账号
  ccp current                 显示当前窗口使用的 profile
  ccp share <name> [条目...]  从 ~\.claude 共享配置（默认：$($ShareItems -join ' ')）
  ccp rm <name>               删除 profile（需确认）
  ccp update                  更新 ccp 到最新版本
  ccp version                 显示版本

profile 存放在：$Root（可用 CCP_HOME 修改）
"@
}

$sub = if ($args.Count -gt 0) { $args[0] } else { 'help' }
$rest = @(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] })

switch ($sub) {
    'add' {
        if ($rest.Count -lt 1) { Fail '用法：ccp add <name>' }
        $name = $rest[0]; Test-Name $name
        if ($name -eq 'default') { Fail 'default 是保留名（指直接运行 claude 时的账号），请换个名字' }
        $d = Get-ProfileDir $name
        if (Test-Path $d) { Write-Host "profile '$name' 已存在：$d" }
        else { New-Item -ItemType Directory -Force $d | Out-Null; Write-Host "已创建 profile '$name'：$d" }
        Write-Host "下一步：ccp login $name  登录该账号"
    }
    'login' {
        if ($rest.Count -lt 1) { Fail '用法：ccp login <name> [claude auth login 参数...]' }
        $name = $rest[0]; Assert-Profile $name
        if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Fail '找不到 claude 命令，请先安装 Claude Code' }
        $loginArgs = @(if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] })
        $old = $env:CLAUDE_CONFIG_DIR; $oldB = $env:BROWSER
        $env:CLAUDE_CONFIG_DIR = Get-ProfileDir $name
        # 默认不自动打开浏览器：Windows 没有 false 程序，指向一个不存在的命令效果相同（启动失败即不打开）
        if (-not $env:BROWSER) { $env:BROWSER = 'false' }
        Write-Host '请复制下面打印的链接到浏览器打开，登录后把授权码粘贴回来'
        try { & claude auth login @loginArgs } finally { $env:CLAUDE_CONFIG_DIR = $old; $env:BROWSER = $oldB }
    }
    'run' {
        if ($rest.Count -lt 1) { Fail '用法：ccp run <name> [claude 参数...]' }
        $name = $rest[0]; $dir = Get-ConfigDir $name
        if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Fail '找不到 claude 命令，请先安装 Claude Code' }
        $claudeArgs = @(if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] })
        $old = $env:CLAUDE_CONFIG_DIR; $oldP = $env:CCP_PROFILE
        # default 不设 CLAUDE_CONFIG_DIR，让 claude 用自己的默认目录
        $env:CLAUDE_CONFIG_DIR = if ($name -eq 'default') { $null } else { $dir }; $env:CCP_PROFILE = $name
        # 退出后恢复，避免影响同一窗口里后续的命令
        try { & claude @claudeArgs } finally { $env:CLAUDE_CONFIG_DIR = $old; $env:CCP_PROFILE = $oldP }
    }
    'take' {
        # 把 <from> 在当前项目最近的（或指定的）会话复制到 <to>，然后用 <to> 接着这个会话
        if ($rest.Count -lt 2) { Fail '用法：ccp take <from> <to> [--session <id>] [claude 参数...]' }
        $from = $rest[0]; $to = $rest[1]
        $fromDir = Get-ConfigDir $from; $toDir = Get-ConfigDir $to
        if ($from -eq $to) { Fail '<from> 和 <to> 不能相同' }
        $more = @(if ($rest.Count -gt 2) { $rest[2..($rest.Count - 1)] })
        $sid = ''
        if ($more.Count -ge 1 -and $more[0] -eq '--session') {
            if ($more.Count -lt 2) { Fail '--session 后面需要会话 ID' }
            $sid = $more[1]
            $more = @(if ($more.Count -gt 2) { $more[2..($more.Count - 1)] })
        }
        # Claude Code 按项目路径存会话：路径中字母数字以外的字符都换成 -
        $key = (Get-Location).Path -replace '[^A-Za-z0-9]', '-'
        $srcDir = Join-Path $fromDir "projects\$key"
        $dstDir = Join-Path $toDir "projects\$key"
        if (-not (Test-Path $srcDir)) { Fail "'$from' 在当前目录（$(Get-Location)）下没有会话" }
        if (-not $sid) {
            $latest = Get-ChildItem $srcDir -Filter *.jsonl | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $latest) { Fail "'$from' 在当前目录下没有会话" }
            $sid = $latest.BaseName
        }
        $srcFile = Join-Path $srcDir "$sid.jsonl"
        if (-not (Test-Path $srcFile)) { Fail "'$from' 在当前目录下找不到会话 $sid" }
        New-Item -ItemType Directory -Force $dstDir | Out-Null
        Copy-Item $srcFile $dstDir -Force
        # 部分版本会把子代理等记录放在同名目录里，一并复制
        $side = Join-Path $srcDir $sid
        if (Test-Path $side -PathType Container) { Copy-Item $side $dstDir -Recurse -Force }
        Write-Host "已把 '$from' 的会话 $sid 复制到 '$to'，正在接着运行…"
        $old = $env:CLAUDE_CONFIG_DIR; $oldP = $env:CCP_PROFILE
        $env:CLAUDE_CONFIG_DIR = if ($to -eq 'default') { $null } else { $toDir }; $env:CCP_PROFILE = $to
        try { & claude --resume $sid @more } finally { $env:CLAUDE_CONFIG_DIR = $old; $env:CCP_PROFILE = $oldP }
    }
    { $_ -in 'list', 'ls' } {
        $dirs = @(if (Test-Path $Root) { Get-ChildItem $Root -Directory })
        if ($dirs.Count -eq 0) { Write-Host '还没有 profile，先运行：ccp add <name>' }
        '{0,-2} {1,-16} {2}' -f '', 'PROFILE', 'ACCOUNT'
        foreach ($d in $dirs) {
            $acct = Get-Account $d.FullName
            $mark = if ($env:CLAUDE_CONFIG_DIR -eq $d.FullName) { '*' } else { '' }
            '{0,-2} {1,-16} {2}' -f $mark, $d.Name, $(if ($acct) { $acct } else { '（未登录）' })
        }
        $acct = Get-Account $HOME
        '{0,-2} {1,-16} {2}' -f '', '(default)', "$(if ($acct) { $acct } else { '（未登录）' })  ← 直接运行 claude 时使用"
    }
    'current' {
        if ($env:CLAUDE_CONFIG_DIR) { "$(Split-Path $env:CLAUDE_CONFIG_DIR -Leaf)  ($env:CLAUDE_CONFIG_DIR)  $(Get-Account $env:CLAUDE_CONFIG_DIR)" }
        else { "(default)  ($DefaultDir)  $(Get-Account $HOME)" }
    }
    'share' {
        if ($rest.Count -lt 1) { Fail "用法：ccp share <name> [条目...]   默认：$($ShareItems -join ' ')" }
        $name = $rest[0]; Assert-Profile $name
        $d = Get-ProfileDir $name
        $items = if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] } else { $ShareItems }
        foreach ($it in $items) {
            if ($Forbidden -contains $it) { Write-Host "跳过 ${it}：账号/会话数据不能共享"; continue }
            $src = Join-Path $DefaultDir $it; $dst = Join-Path $d $it
            if (-not (Test-Path $src)) { Write-Host "跳过 ${it}：$src 不存在"; continue }
            if (Test-Path $dst) {
                $cur = Get-Item $dst -Force
                if ($cur.LinkType -and ($cur.Target -contains $src)) { Write-Host "已链接 $it" }
                else { Write-Host "跳过 ${it}：$dst 已存在（profile 自有版本，不覆盖）" }
                continue
            }
            if ((Get-Item $src).PSIsContainer) {
                # 目录用 Junction，不需要管理员权限
                New-Item -ItemType Junction -Path $dst -Target $src | Out-Null
            } else {
                # 文件软链接需要开发者模式或管理员；不行就退回为复制
                try { New-Item -ItemType SymbolicLink -Path $dst -Target $src | Out-Null }
                catch { Copy-Item $src $dst; Write-Host "  （无权限创建文件链接，已改为复制；更新 $it 后需重新运行 share）" }
            }
            Write-Host "链接 $it -> $src"
        }
    }
    { $_ -in 'rm', 'remove' } {
        if ($rest.Count -lt 1) { Fail '用法：ccp rm <name>' }
        $name = $rest[0]; Test-Name $name
        $d = Get-ProfileDir $name
        if (-not (Test-Path $d)) { Write-Host "profile '$name' 不存在，无需删除"; break }
        $acct = Get-Account $d
        $ans = Read-Host "删除 profile '$name'（$(if ($acct) { $acct } else { '未登录' })），包括其会话历史？[y/N]"
        if ($ans -notmatch '^[yY]$') { Write-Host '已取消'; break }
        # 先移除链接本身，避免递归删除时进入 ~\.claude
        Get-ChildItem $d -Force | Where-Object { $_.LinkType } | ForEach-Object { $_.Delete() }
        Remove-Item $d -Recurse -Force
        Write-Host "已删除 $d"
    }
    { $_ -in 'update', 'upgrade' } {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try { $remote = (Invoke-WebRequest "$RepoRaw/ccp.ps1" -UseBasicParsing).Content }
        catch { Fail "无法连接 GitHub，请检查网络：$_" }
        if ($remote -is [byte[]]) { $remote = [Text.Encoding]::UTF8.GetString($remote) }
        $latest = if ($remote -match "\`$CcpVersion = '([^']+)'") { $Matches[1] } else { '' }
        if ($latest -and $latest -eq $CcpVersion) { Write-Host "已是最新版本：$CcpVersion"; break }
        Write-Host "更新：$CcpVersion -> $(if ($latest) { $latest } else { '最新版' })"
        Invoke-RestMethod "$RepoRaw/install.ps1" | Invoke-Expression
    }
    { $_ -in 'version', '-v', '--version' } { "ccp $CcpVersion" }
    { $_ -in 'help', '-h', '--help' } { Show-Usage }
    default { Fail "未知命令：$sub（运行 ccp help 查看用法）" }
}
