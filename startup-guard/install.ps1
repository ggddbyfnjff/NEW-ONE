#Requires -Version 5.1
<#
.SYNOPSIS
    把「开机启动拦截」安装到当前 Windows 用户，并在桌面创建快捷方式。

.DESCRIPTION
    安装过程不需要管理员权限：
      * 程序文件复制到 %LOCALAPPDATA%\StartupGuard\app
      * 在同一目录生成程序图标
      * 在桌面创建「开机启动拦截」快捷方式（可用 -NoShortcut 跳过）

    开关状态保存在 %LOCALAPPDATA%\StartupGuard\state.json，重装或更新程序
    不会覆盖它。重复运行本脚本即可用当前源文件更新安装。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>

[CmdletBinding()]
param(
    [string]$SourceDir = $PSScriptRoot,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'StartupGuard'),
    [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
    [switch]$NoShortcut,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function New-StartupGuardIcon {
    param([string]$Path)

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new(64, 64, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    $blue = $null
    $white = $null
    $backgroundPath = $null
    $trackPath = $null
    $stream = $null
    $icon = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $blue = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(0, 120, 212))
        $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)

        $backgroundPath = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $backgroundPath.AddArc(2, 2, 16, 16, 180, 90)
        $backgroundPath.AddArc(46, 2, 16, 16, 270, 90)
        $backgroundPath.AddArc(46, 46, 16, 16, 0, 90)
        $backgroundPath.AddArc(2, 46, 16, 16, 90, 90)
        $backgroundPath.CloseFigure()
        $graphics.FillPath($blue, $backgroundPath)

        $trackPath = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $trackPath.AddArc(15, 23, 18, 18, 180, 90)
        $trackPath.AddArc(31, 23, 18, 18, 270, 90)
        $trackPath.AddArc(31, 23, 18, 18, 0, 90)
        $trackPath.AddArc(15, 23, 18, 18, 90, 90)
        $trackPath.CloseFigure()
        $graphics.FillPath($white, $trackPath)
        $graphics.FillEllipse($blue, 34, 25, 14, 14)

        $iconHandle = $bitmap.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($iconHandle)
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        $icon.Save($stream)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $icon) { $icon.Dispose() }
        if ($null -ne $trackPath) { $trackPath.Dispose() }
        if ($null -ne $backgroundPath) { $backgroundPath.Dispose() }
        if ($null -ne $white) { $white.Dispose() }
        if ($null -ne $blue) { $blue.Dispose() }
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
}

$source = (Resolve-Path -LiteralPath $SourceDir).Path
$runtimeFiles = @(
    'StartupGuard.Gui.ps1'
    'StartupGuard.psm1'
    'startup-guard.ps1'
    'startup-guard.cmd'
    'README.md'
)
foreach ($name in $runtimeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name))) {
        throw "安装源缺少文件：$name"
    }
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) { throw 'InstallDir 不能为空。' }
$install = [System.IO.Path]::GetFullPath($InstallDir)
$appDir = Join-Path $install 'app'
New-Item -ItemType Directory -Path $appDir -Force | Out-Null

if ($source.TrimEnd('\') -ne $appDir.TrimEnd('\')) {
    foreach ($name in $runtimeFiles) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $appDir -Force
    }
    $docsSource = Join-Path $source 'docs'
    if (Test-Path -LiteralPath $docsSource) {
        $docsTarget = Join-Path $appDir 'docs'
        New-Item -ItemType Directory -Path $docsTarget -Force | Out-Null
        Copy-Item -Path (Join-Path $docsSource '*') -Destination $docsTarget -Recurse -Force
    }
}

$iconPath = Join-Path $install 'StartupGuard.ico'
New-StartupGuardIcon -Path $iconPath

$shortcutPath = $null
if (-not $NoShortcut) {
    if ([string]::IsNullOrWhiteSpace($DesktopDir)) {
        $DesktopDir = [Environment]::GetFolderPath('Desktop')
    }
    if (-not (Test-Path -LiteralPath $DesktopDir)) {
        New-Item -ItemType Directory -Path $DesktopDir -Force | Out-Null
    }

    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath)) {
        $powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
    }
    $guiPath = Join-Path $appDir 'StartupGuard.Gui.ps1'
    $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $guiPath
    $shortcutPath = Join-Path $DesktopDir '开机启动拦截.lnk'

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $powershellPath
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $install
        $shortcut.IconLocation = "$iconPath,0"
        $shortcut.Description = '开机启动拦截：一键屏蔽开机自动启动项'
        $shortcut.WindowStyle = 1
        $shortcut.Save()

        $verify = $shell.CreateShortcut($shortcutPath)
        if ($verify.TargetPath -ne $powershellPath) {
            throw '桌面快捷方式创建后校验失败。'
        }
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

if (-not $Quiet) {
    Write-Host '安装完成。'
    Write-Host ("  程序目录：{0}" -f $appDir)
    Write-Host ("  程序图标：{0}" -f $iconPath)
    if ($null -ne $shortcutPath) {
        Write-Host ("  桌面快捷方式：{0}" -f $shortcutPath)
        Write-Host '双击桌面上的「开机启动拦截」即可打开开关窗口。'
    }
}

return [pscustomobject]@{
    InstallDir      = $install
    AppDir          = $appDir
    IconPath        = $iconPath
    ShortcutPath    = $shortcutPath
    ShortcutCreated = ($null -ne $shortcutPath)
}
