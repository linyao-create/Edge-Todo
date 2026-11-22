<#
.SYNOPSIS
    为 Windows 版「一角」应用副本绑定独立数据目录与协议策略（写入 edgetodo-config.json）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppDir,

    [Parameter(Mandatory = $true)]
    [string]$DataDir,

    [string]$ProtocolScheme = "edgetodo",

    [switch]$RegisterProtocol,

    [switch]$SkipProtocolRegistration,

    [switch]$ForceRegisterProtocol
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($AppDir)) {
    throw "参数 -AppDir 不能为空。"
}
if ([string]::IsNullOrWhiteSpace($DataDir)) {
    throw "参数 -DataDir 不能为空。"
}

$trimmedAppInput = $AppDir.Trim()
if ($trimmedAppInput -match '^[A-Za-z]:[\\/]?$') {
    throw "不能将磁盘根目录作为应用安装目录：$trimmedAppInput"
}
$trimmedDataInput = $DataDir.Trim()
if ($trimmedDataInput -match '^[A-Za-z]:[\\/]?$') {
    throw "不能将磁盘根目录作为一角数据目录：$trimmedDataInput"
}

$fullAppDir = [System.IO.Path]::GetFullPath($trimmedAppInput)
$rootOfApp = [System.IO.Path]::GetPathRoot($fullAppDir)
if ($fullAppDir.TrimEnd('\', '/') -eq $rootOfApp.TrimEnd('\', '/')) {
    throw "不能将磁盘根目录作为应用安装目录：$fullAppDir"
}
$resolvedAppDir = $fullAppDir.TrimEnd('\', '/')
$exePath = Join-Path $resolvedAppDir "EdgeTodo.exe"
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "在目标应用目录未找到 EdgeTodo.exe：$resolvedAppDir"
}

$fullDataDir = [System.IO.Path]::GetFullPath($trimmedDataInput)
$rootOfData = [System.IO.Path]::GetPathRoot($fullDataDir)
if ($fullDataDir.TrimEnd('\', '/') -eq $rootOfData.TrimEnd('\', '/')) {
    throw "不能将磁盘根目录作为一角数据目录：$fullDataDir"
}

$resolvedDataDir = $fullDataDir.TrimEnd('\', '/')
New-Item -ItemType Directory -Force -Path $resolvedDataDir | Out-Null

$normalizedScheme = $ProtocolScheme.Trim().ToLowerInvariant()
if ($normalizedScheme -notmatch '^[a-z][a-z0-9+\-.]*$') {
    throw "协议名称不合法：$ProtocolScheme"
}

if ($RegisterProtocol -and $SkipProtocolRegistration) {
    throw "-RegisterProtocol 与 -SkipProtocolRegistration 不能同时指定。"
}

function Split-ProtocolCommandTokens([string]$CommandText) {
    $tokens = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $inQuotes = $false
    $hasToken = $false
    foreach ($ch in $CommandText.ToCharArray()) {
        if ($ch -eq '"') {
            $inQuotes = -not $inQuotes
            $hasToken = true
            continue
        }
        if ([char]::IsWhiteSpace($ch) -and -not $inQuotes) {
            if ($hasToken) {
                $tokens.Add($sb.ToString())
                [void]$sb.Clear()
                $hasToken = $false
            }
            continue
        }
        [void]$sb.Append($ch)
        $hasToken = $true
    }
    if ($hasToken) { $tokens.Add($sb.ToString()) }
    return $tokens
}

function Resolve-ExistingProtocolTarget([string]$CommandText) {
    $tokens = @(Split-ProtocolCommandTokens $CommandText)
    if ($tokens.Count -eq 0 -or [string]::IsNullOrWhiteSpace($tokens[0])) {
        return $null
    }
    $exe = $tokens[0]
    $dir = $null
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        if ($t.Equals("--data-dir", [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($i + 1 -lt $tokens.Count -and -not [string]::IsNullOrWhiteSpace($tokens[$i + 1]) -and $tokens[$i + 1] -ne "%1") {
                $dir = $tokens[++$i]
            }
        }
        elseif ($t.StartsWith("--data-dir=", [System.StringComparison]::OrdinalIgnoreCase)) {
            $val = $t.Substring("--data-dir=".Length)
            if (-not [string]::IsNullOrWhiteSpace($val) -and $val -ne "%1") {
                $dir = $val
            }
        }
    }
    return [pscustomobject]@{
        ExecutablePath = $exe
        DataDirectory  = $dir
    }
}

function Get-MergedProtocolCommand([string]$SchemeName) {
    foreach ($rootHive in @("HKCU:\Software\Classes", "HKLM:\Software\Classes")) {
        $regCmdPath = "$rootHive\$SchemeName\shell\open\command"
        if (Test-Path -LiteralPath $regCmdPath) {
            try {
                $prop = Get-ItemProperty -LiteralPath $regCmdPath -ErrorAction Stop
                $rawVal = $prop.'(default)'
                if ($null -eq $rawVal) { continue }
                if ($rawVal -isnot [string]) {
                    return [pscustomobject]@{ ReadFailed = $true; Command = $null }
                }
                if (-not [string]::IsNullOrWhiteSpace($rawVal)) {
                    return [pscustomobject]@{ ReadFailed = $false; Command = $rawVal }
                }
            }
            catch {
                return [pscustomobject]@{ ReadFailed = $true; Command = $null }
            }
        }
    }
    return [pscustomobject]@{ ReadFailed = $false; Command = $null }
}

function Complete-ProtocolRegistration(
    [string]$SchemeName,
    [string]$Command,
    [string]$PendingFile,
    [Microsoft.Win32.RegistryKey]$Registry = [Microsoft.Win32.Registry]::CurrentUser
) {
    $path = 'Software\Classes'
    $schemePath = "$path\$SchemeName"
    $createdKeys = [System.Collections.Generic.List[string]]::new()
    $changes = [System.Collections.Generic.List[object]]::new()
    $keys = [System.Collections.Generic.List[Microsoft.Win32.RegistryKey]]::new()
    try {
        foreach ($part in @($SchemeName, 'shell', 'open', 'command')) {
            $path += "\$part"
            $key = $registry.OpenSubKey($path)
            if ($null -eq $key) {
                $key = $registry.CreateSubKey($path)
                $createdKeys.Add($path)
            }
            $keys.Add($key)
        }

        # Preserve existing protocol metadata and only switch the command after the other values are ready.
        foreach ($entry in @(
            @{ Key = $keys[0]; Path = $schemePath; Name = ''; Value = 'URL:一角'; OnlyIfMissing = $true }
            @{ Key = $keys[0]; Path = $schemePath; Name = 'URL Protocol'; Value = ''; OnlyIfMissing = $true }
            @{ Key = $keys[3]; Path = $path; Name = ''; Value = $Command; OnlyIfMissing = $false }
        )) {
            $exists = $entry.Key.GetValueNames() -contains $entry.Name
            if ($exists -and $entry.OnlyIfMissing) { continue }
            $previous = $entry.Key.GetValue($entry.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($previous -is [string] -and $previous -ceq $entry.Value) { continue }
            $kind = if ($exists) { $entry.Key.GetValueKind($entry.Name) }
            $writableKey = $registry.OpenSubKey($entry.Path, $true)
            if ($null -eq $writableKey) { throw "协议注册表项已被移除：$($entry.Key.Name)" }
            $keys.Add($writableKey)
            $writableKey.SetValue($entry.Name, $entry.Value, [Microsoft.Win32.RegistryValueKind]::String)
            $changes.Add(@{ Key = $writableKey; Name = $entry.Name; Exists = $exists; Value = $previous; Kind = $kind })
        }

        Remove-Item -LiteralPath $PendingFile -Force -ErrorAction Stop
    }
    catch {
        $registrationError = $_
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        for ($i = $changes.Count - 1; $i -ge 0; $i--) {
            $change = $changes[$i]
            try {
                if ($change.Exists) {
                    $change.Key.SetValue($change.Name, $change.Value, $change.Kind)
                }
                else {
                    $change.Key.DeleteValue($change.Name, $false)
                }
            }
            catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        foreach ($key in $keys) { $key.Dispose() }
        $keys.Clear()
        for ($i = $createdKeys.Count - 1; $i -ge 0; $i--) {
            $created = $createdKeys[$i]
            try {
                $key = $registry.OpenSubKey($created)
                if ($null -eq $key) { continue }
                try { $empty = $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0 }
                finally { $key.Dispose() }
                if ($empty) { $registry.DeleteSubKey($created, $false) }
            }
            catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "注册协议失败，且无法完整恢复原注册表：$($rollbackErrors -join ' / ')。原始错误：$($registrationError.Exception.Message)"
        }
        throw
    }
    finally {
        foreach ($key in $keys) { $key.Dispose() }
    }
}

$existingTargetIsThisApp = $false
if ($RegisterProtocol) {
    $merged = Get-MergedProtocolCommand $normalizedScheme
    $parsedTarget = if ($merged.Command) { Resolve-ExistingProtocolTarget $merged.Command }
    if ($parsedTarget) {
        try {
            $existingExe = [System.IO.Path]::GetFullPath($parsedTarget.ExecutablePath.Trim())
            $existingTargetIsThisApp = $existingExe.Equals($exePath, [System.StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            if (-not $ForceRegisterProtocol) { throw }
        }
    }
    if (-not $ForceRegisterProtocol) {
        if ($merged.ReadFailed) {
            throw "读取现有协议注册表失败，已保留原入口；如确认接管请加 -ForceRegisterProtocol。"
        }
        if (-not [string]::IsNullOrWhiteSpace($merged.Command)) {
            if ($null -eq $parsedTarget) {
                throw "现有协议命令无法解析，已保留原入口；如确认接管请加 -ForceRegisterProtocol。"
            }
            $normExistingExe = [System.IO.Path]::GetFullPath($parsedTarget.ExecutablePath.Trim())
            $normCurrentExe = [System.IO.Path]::GetFullPath($exePath)
            if (-not $normExistingExe.Equals($normCurrentExe, [System.StringComparison]::OrdinalIgnoreCase)) {
                if (Test-Path -LiteralPath $normExistingExe -PathType Leaf) {
                    throw "检测到协议 $normalizedScheme 已指向其他现存程序 ($normExistingExe)，已保留原入口；如确认接管请加 -ForceRegisterProtocol。"
                }
            }
            else {
                $boundDir = $null
                if (-not [string]::IsNullOrWhiteSpace($parsedTarget.DataDirectory)) {
                    $boundDir = [System.IO.Path]::GetFullPath($parsedTarget.DataDirectory.Trim()).TrimEnd('\', '/')
                }
                else {
                    $existingExeDir = Split-Path -Parent $normExistingExe
                    $existingCfgPath = Join-Path $existingExeDir "edgetodo-config.json"
                    $existingCfgExists = Test-Path -LiteralPath $existingCfgPath
                    try {
                        $existingCfgArtifacts = @(Get-ChildItem -LiteralPath $existingExeDir -Force -ErrorAction Stop | Where-Object { $_.Name -like 'edgetodo-config.json.*' })
                    }
                    catch {
                        throw "无法检查现有协议指向目录的配置状态，已保留原入口；如确认接管请加 -ForceRegisterProtocol。"
                    }
                    $hasExistingPending = @($existingCfgArtifacts | Where-Object { $_.Name.Equals('edgetodo-config.json.pending', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                    if ($hasExistingPending) {
                        throw "现有协议指向的副本配置未完成，已保留原入口；如确认接管请加 -ForceRegisterProtocol。"
                    }
                    if ($existingCfgExists) {
                        if (Test-Path -LiteralPath $existingCfgPath -PathType Container) {
                            throw "现有协议指向的配置路径被同名文件夹占用，已保留原入口；如确认接管请加 -ForceRegisterProtocol。"
                        }
                        try {
                            $existingCfg = Get-Content -LiteralPath $existingCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            if (-not [string]::IsNullOrWhiteSpace($existingCfg.dataDirectory)) {
                                $rawDir = $existingCfg.dataDirectory.Trim()
                                $comb = if ([System.IO.Path]::IsPathRooted($rawDir)) { $rawDir } else { Join-Path $existingExeDir $rawDir }
                                $boundDir = [System.IO.Path]::GetFullPath($comb).TrimEnd('\', '/')
                            }
                            else {
                                throw "缺少 dataDirectory"
                            }
                        }
                        catch {
                            throw "现有协议指向的配置文件无法解析，已保留原入口；如确认接管请加 -ForceRegisterProtocol。"
                        }
                    }
                    elseif ($existingCfgArtifacts.Count -gt 0) {
                        throw "检测到现有协议指向的目录存在残留配置文件，无法确认归属，已保留原入口；如确认接管请加 -ForceRegisterProtocol。"
                    }
                    if ($null -eq $boundDir) {
                        $boundDir = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "EdgeTodo")).TrimEnd('\', '/')
                    }
                }
                if (-not $boundDir.Equals($resolvedDataDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "检测到协议 $normalizedScheme 已绑定其他数据目录 ($boundDir)，已保留原入口；如确认接管请加 -ForceRegisterProtocol。"
                }
            }
        }
    }
}

$configObject = [ordered]@{
    dataDirectory  = $resolvedDataDir
    protocolScheme = $normalizedScheme
}
if ($SkipProtocolRegistration) {
    $configObject["registerProtocol"] = $false
}

$configPath = Join-Path $resolvedAppDir "edgetodo-config.json"
if (Test-Path -LiteralPath $configPath -PathType Container) {
    throw "配置目标路径被同名文件夹占用：$configPath"
}
$pendingPath = "$configPath.pending"
if (Test-Path -LiteralPath $pendingPath -PathType Container) {
    throw "配置状态标记路径被同名文件夹占用：$pendingPath"
}
$pendingExisted = Test-Path -LiteralPath $pendingPath
$configExisted = [System.IO.File]::Exists($configPath)

$tempPath = "$configPath.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
$backupPath = "$configPath.$PID.$([Guid]::NewGuid().ToString('N')).bak"
$json = $configObject | ConvertTo-Json -Depth 3
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$tempWritten = $false
$configInstalled = $false

# 写入「配置进行中」标记文件；在主配置就位及协议写入全部完成前一直保留，任何中途失败都会阻止副本误回退默认目录
if (-not $pendingExisted) {
    [System.IO.File]::WriteAllText($pendingPath, "{`"pid`": $PID, `"startedAt`": `"$((Get-Date).ToString('o'))`"}" + [Environment]::NewLine, $utf8NoBom)
}

try {
    [System.IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, $utf8NoBom)
    $tempWritten = $true
    if ($configExisted) {
        [System.IO.File]::Replace($tempPath, $configPath, $backupPath, $true)
    }
    else {
        [System.IO.File]::Move($tempPath, $configPath)
    }
    $configInstalled = $true
    if ($RegisterProtocol) {
        Complete-ProtocolRegistration $normalizedScheme "`"$exePath`" --data-dir `"$resolvedDataDir`" `"%1`"" $pendingPath
    }
    else {
        Remove-Item -LiteralPath $pendingPath -Force -ErrorAction Stop
    }
}
catch {
    $configurationError = $_
    try {
        if ([System.IO.File]::Exists($backupPath)) {
            if ([System.IO.File]::Exists($configPath)) {
                [System.IO.File]::Replace($backupPath, $configPath, [NullString]::Value, $true)
            }
            else {
                [System.IO.File]::Move($backupPath, $configPath)
            }
        }
        elseif ($configInstalled -and -not $configExisted -and $existingTargetIsThisApp) {
            [System.IO.File]::Delete($configPath)
        }
        if ($configExisted -and -not [System.IO.File]::Exists($configPath)) {
            throw "找不到原配置文件：$configPath"
        }
        # A prior installation can start again once its original config is back.
        if (($configExisted -or $existingTargetIsThisApp) -and -not $pendingExisted) {
            [System.IO.File]::Delete($pendingPath)
        }
    }
    catch {
        throw "配置失败，且无法自动恢复原应用配置：$($_.Exception.Message)。检查旧配置备份 $backupPath 。原始错误：$($configurationError.Exception.Message)"
    }
    throw
}
finally {
    # 仅在未写完临时文件，或主配置/备份至少有一个存在时清理临时文件，避免极端双失
    if ((Test-Path -LiteralPath $tempPath -PathType Leaf) -and ((-not $tempWritten) -or (Test-Path -LiteralPath $configPath -PathType Leaf) -or (Test-Path -LiteralPath $backupPath -PathType Leaf))) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
}

$leftoverArtifacts = @(Get-ChildItem -LiteralPath $resolvedAppDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'edgetodo-config.json.*' -and ($_.Name -like '*.bak' -or $_.Name -like '*.tmp') })
if ($leftoverArtifacts.Count -gt 0) {
    Write-Host "Notice: Leftover config backup/temp files from previous runs were preserved (not deleted automatically):"
    foreach ($artifact in $leftoverArtifacts) {
        Write-Host "  - $($artifact.FullName)"
    }
    Write-Host "You may inspect and delete them manually if no longer needed."
}

Write-Host "Configured EdgeTodo.exe: $exePath"
Write-Host "Data directory: $resolvedDataDir"
Write-Host "Protocol scheme: $normalizedScheme"
Write-Host "Config file: $configPath"
