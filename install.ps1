# ccp 安装脚本（Windows）。可重复运行：已安装则覆盖为最新版本，$PROFILE 只添加一次。
# 在线安装：irm https://raw.githubusercontent.com/1359484419/ccp/main/install.ps1 | iex
# 本地安装：双击 install.cmd
# 注意：本文件必须保持无 BOM。irm | iex 会把 BOM 当成命令名报错；install.cmd 用 UTF-8 显式读取本文件，所以中文不会乱码。
# 整体包在脚本块里：通过 iex 运行时不污染用户会话的变量，出错也不会关掉用户的窗口
& {
    $ErrorActionPreference = 'Stop'
    $repoRaw = if ($env:CCP_REPO_RAW) { $env:CCP_REPO_RAW } else { 'https://raw.githubusercontent.com/1359484419/ccp/main' }

    $binDir = Join-Path $HOME 'bin'
    New-Item -ItemType Directory -Force $binDir | Out-Null
    $dst = Join-Path $binDir 'ccp.ps1'
    $tmp = "$dst.tmp"

    # 本地运行时从脚本所在目录复制（install.cmd 通过 CCP_SRC_DIR 传入目录）；通过 irm | iex 运行时改为在线下载
    $srcDir = if ($env:CCP_SRC_DIR) { $env:CCP_SRC_DIR } elseif ($PSScriptRoot) { $PSScriptRoot } else { '' }
    $local = if ($srcDir) { Join-Path $srcDir 'ccp.ps1' } else { '' }
    if ($local -and (Test-Path $local)) {
        Copy-Item $local $tmp -Force
    } else {
        Write-Host "下载 ccp：$repoRaw/ccp.ps1"
        # Windows PowerShell 5.1 默认可能不启用 TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try { Invoke-WebRequest "$repoRaw/ccp.ps1" -OutFile $tmp -UseBasicParsing }
        catch { Write-Host "下载失败：$_" -ForegroundColor Red; return }
    }
    Move-Item $tmp $dst -Force
    # 通过微信/邮件/浏览器收到的文件带有"来自互联网"标记，RemoteSigned 会拦截，需解除
    Unblock-File $dst
    Write-Host "已安装：$dst"

    # 允许当前用户运行本地脚本（$PROFILE 和 ccp.ps1 都需要）
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -in 'Undefined', 'Restricted', 'AllSigned') {
        try {
            Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
            Write-Host '已将当前用户的脚本执行策略设为 RemoteSigned'
        } catch {
            Write-Host '无法修改执行策略（可能被组策略限制），请联系 IT 或手动执行：Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' -ForegroundColor Yellow
        }
    }

    # 在 PowerShell 配置文件里注册 ccp 函数（Windows PowerShell 5.1 和 PowerShell 7 的 $PROFILE 路径不同，都写上）
    $mark = '# added by ccp installer'
    $line = 'function ccp { & "$HOME\bin\ccp.ps1" @args }'
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $profiles = @(
        (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
    )
    foreach ($p in $profiles) {
        if ((Test-Path $p) -and (Select-String -Path $p -SimpleMatch $mark -Quiet)) {
            Write-Host "$p 已配置过 ccp"
            continue
        }
        New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
        Add-Content -Path $p -Value "`r`n$mark`r`n$line" -Encoding UTF8
        Write-Host "已注册 ccp 命令：$p"
    }

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Host '注意：没找到 claude 命令，请先安装 Claude Code' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '安装完成。请重新打开 PowerShell 窗口，然后：' -ForegroundColor Green
    Write-Host '  ccp add work'
    Write-Host '  ccp login work'
    Write-Host '  ccp run work'
}
