<#
.SYNOPSIS
    构建并发布 Windows 版「一角」桌面客户端与命令行工具（基于 .NET 10）。
#>
[CmdletBinding()]
param(
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "dist\windows"
}

$trimmedOut = $OutputDir.Trim()
if ($trimmedOut -match '^[A-Za-z]:[\\/]?$') {
    throw "不能直接将磁盘根目录作为发布输出目录：$trimmedOut"
}
$fullOut = [System.IO.Path]::GetFullPath($trimmedOut)
$rootOut = [System.IO.Path]::GetPathRoot($fullOut)
if ($fullOut.TrimEnd('\', '/') -eq $rootOut.TrimEnd('\', '/')) {
    throw "不能直接将磁盘根目录作为发布输出目录：$fullOut"
}
$resolvedOut = $fullOut.TrimEnd('\', '/')
$parentOut = Split-Path -Parent $resolvedOut
$leafOut = Split-Path -Leaf $resolvedOut
if ([string]::IsNullOrEmpty($parentOut) -or [string]::IsNullOrEmpty($leafOut)) {
    throw "不能直接将磁盘根目录作为发布输出目录：$resolvedOut"
}
New-Item -ItemType Directory -Force -Path $parentOut | Out-Null

$dotnetVersion = & dotnet --version
if ($LASTEXITCODE -ne 0) {
    throw "未检测到 dotnet 命令，请先安装 Microsoft .NET 10 SDK。"
}

$stagingDir = Join-Path $parentOut (".edgetodo-publish-staging.$PID." + [Guid]::NewGuid().ToString('N'))
$backupDir = $null
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

try {
    Write-Host "Using .NET SDK: $dotnetVersion"
    Write-Host "Publishing EdgeTodo.App -> staging..."
    & dotnet publish (Join-Path $scriptDir "EdgeTodo.App\EdgeTodo.App.csproj") -c Release -o $stagingDir
    if ($LASTEXITCODE -ne 0) { throw "EdgeTodo.App 发布失败。" }

    Write-Host "Publishing EdgeTodo.Cli -> staging..."
    & dotnet publish (Join-Path $scriptDir "EdgeTodo.Cli\EdgeTodo.Cli.csproj") -c Release -o $stagingDir
    if ($LASTEXITCODE -ne 0) { throw "EdgeTodo.Cli 发布失败。" }

    $stagedApp = Join-Path $stagingDir "EdgeTodo.exe"
    $stagedCli = Join-Path $stagingDir "EdgeTodoCmd.exe"
    if (-not (Test-Path -LiteralPath $stagedApp -PathType Leaf) -or -not (Test-Path -LiteralPath $stagedCli -PathType Leaf)) {
        throw "发布校验失败，暂存目录中缺少 EdgeTodo.exe 或 EdgeTodoCmd.exe。"
    }

    if (Test-Path -LiteralPath $resolvedOut -PathType Leaf) {
        throw "输出目标路径已存在同名文件：$resolvedOut"
    }

    if (-not (Test-Path -LiteralPath $resolvedOut)) {
        [System.IO.Directory]::Move($stagingDir, $resolvedOut)
        Write-Host "Publish succeeded: $resolvedOut"
    }
    else {
        # 记录本次新发布产物的顶层条目名称，旧目录中其余所有自定义文件、配置与子目录均原样继承到新版中
        $publishedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        Get-ChildItem -LiteralPath $stagingDir -Force | ForEach-Object {
            [void]$publishedNames.Add($_.Name)
        }
        Get-ChildItem -LiteralPath $resolvedOut -Force | ForEach-Object {
            if (-not $publishedNames.Contains($_.Name)) {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stagingDir $_.Name) -Recurse -Force
            }
        }

        $stamp = (Get-Date -Format "yyyyMMdd-HHmmss") + "." + [Guid]::NewGuid().ToString('N').Substring(0, 6)
        $backupDir = Join-Path $parentOut "$leafOut.backup.$stamp"

        [System.IO.Directory]::Move($resolvedOut, $backupDir)
        $swapped = $false
        try {
            [System.IO.Directory]::Move($stagingDir, $resolvedOut)
            $swapped = $true
        }
        catch {
            $swapError = $_
            if ((Test-Path -LiteralPath $backupDir) -and -not (Test-Path -LiteralPath $resolvedOut)) {
                try {
                    [System.IO.Directory]::Move($backupDir, $resolvedOut)
                }
                catch {
                    Write-Host "Backup preserved at: $backupDir"
                    throw "发布切换失败且回滚原目录失败，已完整保留旧目录备份，请勿删除并手动核对：$backupDir 。原始错误：$($swapError.Exception.Message)"
                }
            }
            throw
        }

        if ($swapped) {
            Write-Host "Publish succeeded: $resolvedOut"
            Write-Host "Previous installation preserved at: $backupDir"
        }
    }
}
finally {
    # 仅清理尚未交付的临时暂存目录，绝不删除任何旧目录备份
    if (Test-Path -LiteralPath $stagingDir) {
        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
