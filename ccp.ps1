# ccp - Claude Code profile 管理器（Windows PowerShell 5.1+ / PowerShell 7）
# 每个 profile 是一个独立的 CLAUDE_CONFIG_DIR，对应一个账号，登录态/会话/设置互相隔离。
# 用法与 macOS 版一致：ccp add/run/list/current/share/rm

$ErrorActionPreference = 'Stop'

$CcpVersion = '1.4.0'
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

# 按 x.y.z 数字逐段比较版本号：a>b 返回 1，相等返回 0，a<b 返回 -1（缺的段按 0 算）
function Compare-Version($a, $b) {
    $pa = @($a.Split('.')); $pb = @($b.Split('.'))
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $pa.Count) { [int]$pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { [int]$pb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

# 两个文件内容是否完全相同（先比大小，再比哈希）
function Test-SameContent($p1, $p2) {
    if ((Get-Item $p1 -Force).Length -ne (Get-Item $p2 -Force).Length) { return $false }
    return (Get-FileHash $p1 -Algorithm SHA256).Hash -eq (Get-FileHash $p2 -Algorithm SHA256).Hash
}

# Claude Code 按项目路径存会话：路径中字母数字以外的字符都换成 -
function Get-ProjectKey { (Get-Location).Path -replace '[^A-Za-z0-9]', '-' }

# 至少有一条 AI 回复才算真正的会话。只打开过 claude、或只执行过 /clear、/model 等命令也会生成会话文件，但里面没有对话
function Test-HasReply($file) { [bool](Select-String -LiteralPath $file -SimpleMatch '"type":"assistant"' -Quiet) }

# 会话 ID、修改时间、标题（优先用 claude 生成的标题，没有则用最后一次输入的内容）
function Get-SessionLine($file) {
    $t = ''
    foreach ($pat in '"aiTitle":"([^"]*)"', '"lastPrompt":"([^"]*)"') {
        $m = Select-String -LiteralPath $file -Pattern $pat -Encoding UTF8 | Select-Object -Last 1
        if ($m) { $t = $m.Matches[0].Groups[1].Value; break }
    }
    if ($t.Length -gt 60) { $t = $t.Substring(0, 60) }
    $f = Get-Item -LiteralPath $file -Force
    '{0}  {1}  {2}' -f $f.BaseName, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $t
}

function Show-Usage {
    @"
ccp - Claude Code profile 管理器（一个 profile = 一个账号）

  ccp add <name>              创建 profile
  ccp login <name> [参数...]  登录该 profile 的账号（只打印链接，不自动开浏览器；name 可用 default）
  ccp run <name> [参数...]    用该 profile 启动 claude（参数原样传给 claude；name 可用 default）
  ccp take <from> <to> [参数...]  把 <from> 在当前项目最近的会话（跳过空会话）复制到 <to> 并接着运行
                              （--session <id> 指定会话；--force 允许覆盖 <to> 里更新的同名会话；
                               其余参数原样传给 claude；from/to 可用 default，即直接运行 claude 时的账号）
  ccp sessions <name>         列出该账号在当前项目的会话（ID、时间、标题），配合 take --session 使用
  ccp list                    列出所有 profile 及登录账号
  ccp current                 显示当前窗口使用的 profile
  ccp share <name> [条目...]  从 ~\.claude 共享配置（默认：$($ShareItems -join ' ')）
  ccp rm <name>               删除 profile（需确认）
  ccp update [--force]        更新 ccp 到最新版本（--force：无论版本如何都重新安装）
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
        $name = $rest[0]; $dir = Get-ConfigDir $name
        if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Fail '找不到 claude 命令，请先安装 Claude Code' }
        $loginArgs = @(if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] })
        $old = $env:CLAUDE_CONFIG_DIR; $oldB = $env:BROWSER
        # default 不设 CLAUDE_CONFIG_DIR（外层设置了也清掉），让 claude 登录到自己的默认目录
        $env:CLAUDE_CONFIG_DIR = if ($name -eq 'default') { $null } else { $dir }
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
        if ($rest.Count -lt 2) { Fail '用法：ccp take <from> <to> [--session <id>] [--force] [claude 参数...]' }
        $from = $rest[0]; $to = $rest[1]
        $fromDir = Get-ConfigDir $from; $toDir = Get-ConfigDir $to
        if ($from -eq $to) { Fail '<from> 和 <to> 不能相同' }
        $more = @(if ($rest.Count -gt 2) { $rest[2..($rest.Count - 1)] })
        $sid = ''; $force = $false
        # --session / --force 顺序任意；遇到第一个不认识的参数即视为 claude 参数开始
        $i = 0
        while ($i -lt $more.Count) {
            if ($more[$i] -eq '--session') {
                if ($i + 1 -ge $more.Count -or -not $more[$i + 1]) { Fail '--session 后面需要会话 ID' }
                $sid = $more[$i + 1]; $i += 2
                # 会话 ID 会拼进路径，只允许字母、数字、- 和 _，防止 ..\ 之类越出会话目录
                if ($sid -notmatch '^[A-Za-z0-9_-]+$') { Fail "会话 ID 格式不对：'$sid'" }
            } elseif ($more[$i] -eq '--force') {
                $force = $true; $i += 1
            } else { break }
        }
        $more = @(if ($i -lt $more.Count) { $more[$i..($more.Count - 1)] })
        $key = Get-ProjectKey
        $srcDir = Join-Path (Join-Path $fromDir 'projects') $key
        $dstDir = Join-Path (Join-Path $toDir 'projects') $key
        if (-not (Test-Path $srcDir)) { Fail "'$from' 在当前目录（$(Get-Location)）下没有会话" }
        if (-not $sid) {
            # 取最近一个有对话的会话，跳过空会话（否则额度用完后再打开一次 claude，就会选中那个空会话）
            $latest = $null; $skipped = 0
            foreach ($f in @(Get-ChildItem $srcDir -Filter *.jsonl | Sort-Object LastWriteTime -Descending)) {
                if (Test-HasReply $f.FullName) { $latest = $f; break }
                $skipped++
            }
            if (-not $latest) { Fail "'$from' 在当前目录下没有包含对话的会话" }
            $sid = $latest.BaseName
            if ($skipped) { Write-Host "已跳过 $($skipped) 个更新但没有对话内容的会话" }
        }
        $srcFile = Join-Path $srcDir "$sid.jsonl"
        if (-not (Test-Path $srcFile -PathType Leaf)) { Fail "'$from' 在当前目录下找不到会话 $($sid)（用 ccp sessions $from 查看）" }
        Write-Host "会话：$(Get-SessionLine $srcFile)"
        $dstFile = Join-Path $dstDir "$sid.jsonl"
        $copy = $true; $backup = ''
        if (Test-Path $dstFile -PathType Leaf) {
            if (Test-SameContent $srcFile $dstFile) {
                # 内容完全相同：不用复制，直接接着运行
                $copy = $false
            } elseif (-not $force -and (Get-Item $dstFile -Force).LastWriteTime -gt (Get-Item $srcFile -Force).LastWriteTime) {
                # 目标更新，说明已经在 <to> 上接着跑过，直接覆盖会丢进度
                Fail "'$to' 里的会话 $sid 比 '$from' 的更新（可能已在 '$to' 上继续过），为避免覆盖进度已停止；确认覆盖请加 --force"
            } else {
                # 覆盖前先备份（同目录 <sid>.jsonl.bak，覆盖旧备份）
                $backup = "$dstFile.bak"
                Copy-Item $dstFile $backup -Force
            }
        }
        if ($copy) {
            New-Item -ItemType Directory -Force $dstDir | Out-Null
            Copy-Item $srcFile $dstFile -Force
        }
        # 部分版本会把子代理等记录放在同名目录里，一并复制
        # （复制目录内容而不是目录本身：目标目录已存在时 Copy-Item 会嵌套成 <sid>\<sid>）
        $side = Join-Path $srcDir $sid
        if (Test-Path $side -PathType Container) {
            $dstSide = Join-Path $dstDir $sid
            New-Item -ItemType Directory -Force $dstSide | Out-Null
            Copy-Item (Join-Path $side '*') $dstSide -Recurse -Force
        }
        if (-not $copy) { Write-Host "'$to' 里的会话 $sid 已是最新（与 '$from' 相同），正在接着运行…" }
        else {
            if ($backup) { Write-Host "'$to' 里原有的会话 $sid 已备份到：$backup" }
            Write-Host "已把 '$from' 的会话 $sid 复制到 '$to'，正在接着运行…"
        }
        $old = $env:CLAUDE_CONFIG_DIR; $oldP = $env:CCP_PROFILE
        $env:CLAUDE_CONFIG_DIR = if ($to -eq 'default') { $null } else { $toDir }; $env:CCP_PROFILE = $to
        try { & claude --resume $sid @more } finally { $env:CLAUDE_CONFIG_DIR = $old; $env:CCP_PROFILE = $oldP }
    }
    'sessions' {
        # 列出 <name> 在当前项目下的会话（新的在前），空会话不列出
        if ($rest.Count -lt 1) { Fail '用法：ccp sessions <name>' }
        $name = $rest[0]
        $dir = Join-Path (Join-Path (Get-ConfigDir $name) 'projects') (Get-ProjectKey)
        if (-not (Test-Path $dir)) { Fail "'$name' 在当前目录（$(Get-Location)）下没有会话" }
        $n = 0; $empty = 0
        foreach ($f in @(Get-ChildItem $dir -Filter *.jsonl | Sort-Object LastWriteTime -Descending)) {
            if (Test-HasReply $f.FullName) { Get-SessionLine $f.FullName; $n++ } else { $empty++ }
        }
        if (-not $n) { Write-Host "'$name' 在当前目录下没有包含对话的会话" }
        if ($empty) { Write-Host "（另有 $($empty) 个没有对话内容的会话未列出）" }
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
        $name = $rest[0]
        if ($name -eq 'default') { Fail 'default 是保留名（指直接运行 claude 时的 ~\.claude），配置本来就在那里，不需要共享' }
        Assert-Profile $name
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
        if ($name -eq 'default') { Fail 'default 是保留名（指直接运行 claude 时的 ~\.claude），不能删除' }
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
        $force = $false
        foreach ($a in $rest) {
            if ($a -eq '--force') { $force = $true }
            else { Fail "未知参数：$a（用法：ccp update [--force]）" }
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try { $remote = (Invoke-WebRequest "$RepoRaw/ccp.ps1" -UseBasicParsing).Content }
        catch { Fail "无法连接 GitHub，请检查网络：$_" }
        if ($remote -is [byte[]]) { $remote = [Text.Encoding]::UTF8.GetString($remote) }
        # 读不到版本号就不装，避免把下载失败的页面或损坏内容当成新版
        $latest = if ($remote -match "(?m)^\`$CcpVersion = '(\d+(\.\d+)*)'") { $Matches[1] } else { '' }
        if (-not $latest) { Fail '无法从远端 ccp.ps1 读出版本号，已取消更新（可稍后重试，或检查 CCP_REPO_RAW）' }
        $cmp = Compare-Version $latest $CcpVersion
        if ($force) { Write-Host "强制重新安装：$CcpVersion -> $latest" }
        elseif ($cmp -eq 0) { Write-Host "已是最新版本：$CcpVersion"; break }
        elseif ($cmp -lt 0) { Write-Host "本地版本 $CcpVersion 比远端 $latest 新（GitHub 下载链接可能还有几分钟缓存），已跳过"; break }
        else { Write-Host "更新：$CcpVersion -> $latest" }
        try { $installer = (Invoke-WebRequest "$RepoRaw/install.ps1" -UseBasicParsing).Content }
        catch { Fail "无法下载安装脚本，请检查网络：$_" }
        if ($installer -is [byte[]]) { $installer = [Text.Encoding]::UTF8.GetString($installer) }
        # 去掉开头的 BOM（U+FEFF）：Invoke-Expression 不认它，会把第一行当成命令名而报错
        $installer.TrimStart([char]0xFEFF) | Invoke-Expression
    }
    { $_ -in 'version', '-v', '--version' } { "ccp $CcpVersion" }
    { $_ -in 'help', '-h', '--help' } { Show-Usage }
    default { Fail "未知命令：$sub（运行 ccp help 查看用法）" }
}
