#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained integration tests for Startup Guard.

.DESCRIPTION
    Runs against Windows PowerShell 5.1.  Every registry write is confined to
    a disposable HKCU test key (Software\StartupGuardTests\<guid>) and a
    temporary folder, so the real startup configuration is never touched.
    The suite also snapshots the real StartupApproved keys and fails if their
    contents changed.

    No Pester dependency.  Run:
        powershell -NoProfile -ExecutionPolicy Bypass -File StartupGuard.Tests.ps1
#>

[CmdletBinding()]
param(
    [string]$ModuleRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ModuleRoot)) {
    $ModuleRoot = Split-Path -Parent $PSScriptRoot
}

Import-Module (Join-Path $ModuleRoot 'StartupGuard.psm1') -Force

$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

$script:Sandbox = 'Software\StartupGuardTests\' + [guid]::NewGuid().ToString('N')
$script:Paths = Get-StartupGuardPaths -SandboxRoot $script:Sandbox
$script:StatePath = $script:Paths.StatePath
$script:SandboxDir = Split-Path -Parent (Split-Path -Parent $script:Paths.StartupFolders[0].Path)
$script:Registry = [Microsoft.Win32.Registry]::CurrentUser

function Get-RealApprovalSnapshot {
    $snapshot = @{}
    foreach ($variant in @('Run', 'Run32', 'StartupFolder')) {
        $subKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\' + $variant
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subKey, $false)
        if ($null -eq $key) { continue }
        try {
            foreach ($name in $key.GetValueNames()) {
                $raw = $key.GetValue($name, $null)
                if ($raw -is [byte[]]) {
                    $snapshot["$variant|$name"] = [Convert]::ToBase64String($raw)
                }
            }
        }
        finally { $key.Close() }
    }
    return $snapshot
}

$script:RealApprovalSnapshot = Get-RealApprovalSnapshot

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Expected condition to be true.')
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message = 'Expected condition to be false.')
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) {
        throw ("Expected [{0}] but got [{1}]. {2}" -f $Expected, $Actual, $Message)
    }
}

function Reset-Sandbox {
    $script:Registry.DeleteSubKeyTree($script:Sandbox, $false)
    if (Test-Path -LiteralPath $script:SandboxDir) {
        Remove-Item -LiteralPath $script:SandboxDir -Recurse -Force
    }
    foreach ($folder in @($script:Paths.StartupFolders)) {
        New-Item -ItemType Directory -Path $folder.Path -Force | Out-Null
    }
}

function Add-TestRunValue {
    param([string]$SourceId, [string]$Name, [string]$Command)
    $source = $script:Paths.Sources | Where-Object { $_.Id -eq $SourceId } | Select-Object -First 1
    Assert-True ($null -ne $source) "Unknown source id: $SourceId"
    $key = $script:Registry.CreateSubKey($source.SubKey)
    try { $key.SetValue($Name, $Command, [Microsoft.Win32.RegistryValueKind]::String) }
    finally { $key.Close() }
}

function Remove-TestRunValue {
    param([string]$SourceId, [string]$Name)
    $source = $script:Paths.Sources | Where-Object { $_.Id -eq $SourceId } | Select-Object -First 1
    $key = $script:Registry.OpenSubKey($source.SubKey, $true)
    if ($null -eq $key) { return }
    try { $key.DeleteValue($Name, $false) } finally { $key.Close() }
}

function Add-TestShortcut {
    param([string]$FolderId, [string]$FileName, [string]$Target, [string]$Arguments = '')
    $folder = $script:Paths.StartupFolders | Where-Object { $_.Id -eq $FolderId } | Select-Object -First 1
    Assert-True ($null -ne $folder) "Unknown folder id: $FolderId"
    $shortcutPath = Join-Path $folder.Path $FileName
    if ($Target) {
        $shell = New-Object -ComObject WScript.Shell
        try {
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $Target
            if ($Arguments) { $shortcut.Arguments = $Arguments }
            $shortcut.Save()
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
    else {
        Set-Content -LiteralPath $shortcutPath -Value 'test shortcut'
    }
}

function Get-TestApproval {
    param([string]$Name, [string]$Variant)
    $subKey = $script:Paths.ApprovalSubKey + '\' + $Variant
    $key = $script:Registry.OpenSubKey($subKey, $false)
    if ($null -eq $key) { return $null }
    try { return $key.GetValue($Name, $null) }
    finally { $key.Close() }
}

function Set-TestApproval {
    param([string]$Name, [string]$Variant, [byte[]]$Bytes)
    $subKey = $script:Paths.ApprovalSubKey + '\' + $Variant
    $key = $script:Registry.CreateSubKey($subKey)
    try { $key.SetValue($Name, [byte[]]$Bytes, [Microsoft.Win32.RegistryValueKind]::Binary) }
    finally { $key.Close() }
}

function Assert-ApprovalByte {
    param([string]$Name, [string]$Variant, [int]$Expected)
    $bytes = Get-TestApproval -Name $Name -Variant $Variant
    Assert-True ($null -ne $bytes) "Expected an approval value for $Name ($Variant)."
    Assert-Equal $Expected ([int]$bytes[0]) "Approval status byte for $Name ($Variant)."
}

function Get-Status {
    return (Get-StartupGuardStatus -SandboxRoot $script:Sandbox -StatePath $script:StatePath)
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    Reset-Sandbox
    try {
        & $Body
        $script:Pass++
        Write-Host ('PASS  {0}' -f $Name) -ForegroundColor Green
    }
    catch {
        $script:Fail++
        $script:Failures.Add($Name)
        Write-Host ('FAIL  {0}' -f $Name) -ForegroundColor Red
        Write-Host ('      {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
}

try {
    Invoke-Test 'finds Run, Run32 and startup-folder entries' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        Add-TestRunValue -SourceId 'MachineRun' -Name 'AppB' -Command 'C:\B\b.exe'
        Add-TestRunValue -SourceId 'MachineRun32' -Name 'AppC' -Command 'C:\C\c.exe'
        Add-TestShortcut -FolderId 'UserStartupFolder' -FileName 'AppD.lnk' -Target 'C:\D\d.exe' -Arguments '--tray'

        $status = Get-Status
        Assert-Equal 4 $status.Counts.Total
        Assert-Equal 4 $status.Counts.Enabled
        Assert-Equal 'Off' $status.Switch
        $shortcutEntry = $status.Entries | Where-Object { $_.Name -eq 'AppD.lnk' } | Select-Object -First 1
        Assert-True ($null -ne $shortcutEntry) 'The startup-folder shortcut was not listed.'
        Assert-True ($shortcutEntry.Command -like 'C:\D\d.exe*') "Shortcut target was not resolved: $($shortcutEntry.Command)"
    }

    Invoke-Test 'blocks enabled entries and leaves already-disabled entries alone' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppB' -Command 'C:\B\b.exe'
        Set-TestApproval -Name 'AppB' -Variant 'Run' -Bytes ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

        $result = Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-Equal 'On' $result.Switch
        Assert-Equal 1 @($result.Blocked).Count
        Assert-ApprovalByte -Name 'AppA' -Variant 'Run' -Expected 3
        Assert-ApprovalByte -Name 'AppB' -Variant 'Run' -Expected 3

        $status = Get-Status
        Assert-Equal 1 $status.Counts.Blocked
        Assert-Equal 1 $status.Counts.Disabled
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        Assert-Equal 'on' $state.switch
        Assert-Equal 1 @($state.disabled).Count
    }

    Invoke-Test 'off removes overlays that did not exist before' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        $on = Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-Equal 'On' $on.Switch
        Assert-ApprovalByte -Name 'AppA' -Variant 'Run' -Expected 3

        $off = Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-Equal 'Off' $off.Switch
        Assert-True ($null -eq (Get-TestApproval -Name 'AppA' -Variant 'Run')) 'The overlay was not removed.'
        $status = Get-Status
        Assert-Equal 0 $status.Counts.Blocked
        Assert-Equal 1 $status.Counts.Enabled
    }

    Invoke-Test 'off restores previous enabled bytes exactly' {
        $original = [byte[]](2, 0, 0, 0, 17, 34, 51, 68, 85, 102, 119, 136)
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        Set-TestApproval -Name 'AppA' -Variant 'Run' -Bytes $original

        Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Assert-ApprovalByte -Name 'AppA' -Variant 'Run' -Expected 3

        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        $restored = Get-TestApproval -Name 'AppA' -Variant 'Run'
        Assert-Equal ([Convert]::ToBase64String($original)) ([Convert]::ToBase64String([byte[]]$restored))
    }

    Invoke-Test 're-applies a recorded entry that drifted back on' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null

        Set-TestApproval -Name 'AppA' -Variant 'Run' -Bytes ([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        $drifted = Get-Status
        Assert-Equal 'On' $drifted.Switch
        Assert-True (@($drifted.Drift) -contains 'AppA') 'Drift was not reported.'

        $again = Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-True (@($again.Reapplied) -contains 'AppA') 'The drifted entry was not re-applied.'
        Assert-ApprovalByte -Name 'AppA' -Variant 'Run' -Expected 3
        $after = Get-Status
        Assert-Equal 0 @($after.Drift).Count

        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
    }

    Invoke-Test 'exclusion prevents blocking and releases an existing block' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppB' -Command 'C:\B\b.exe'

        Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Assert-ApprovalByte -Name 'AppA' -Variant 'Run' -Expected 3
        Assert-ApprovalByte -Name 'AppB' -Variant 'Run' -Expected 3

        $excluded = Set-StartupGuardSwitch -State On -Exclude 'AppA' -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-True (@($excluded.ExclusionsRestored) -contains 'AppA') 'The excluded entry was not released.'
        Assert-True ($null -eq (Get-TestApproval -Name 'AppA' -Variant 'Run')) 'The excluded entry still has an overlay.'
        Assert-ApprovalByte -Name 'AppB' -Variant 'Run' -Expected 3

        $status = Get-Status
        Assert-Equal 1 $status.Counts.Blocked
        Assert-Equal 1 $status.Counts.Excluded
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        Assert-Equal 'AppA' (@($state.excluded) -join ',')

        # A later "on" without -Exclude keeps the stored exclusion.
        Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Assert-True ($null -eq (Get-TestApproval -Name 'AppA' -Variant 'Run')) 'The stored exclusion was not respected.'

        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Assert-True ($null -eq (Get-TestApproval -Name 'AppB' -Variant 'Run')) 'The non-excluded entry was not restored.'
    }

    Invoke-Test 'startup-folder shortcuts are blocked and restored' {
        Add-TestShortcut -FolderId 'UserStartupFolder' -FileName 'AppD.lnk' -Target 'C:\D\d.exe'
        $on = Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-True (@($on.Blocked) -contains 'AppD.lnk') 'The shortcut was not blocked.'
        Assert-ApprovalByte -Name 'AppD.lnk' -Variant 'StartupFolder' -Expected 3
        $status = Get-Status
        Assert-Equal 1 $status.Counts.Blocked
        Assert-Equal 1 $status.Counts.Total

        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Assert-True ($null -eq (Get-TestApproval -Name 'AppD.lnk' -Variant 'StartupFolder')) 'The shortcut overlay was not removed.'
    }

    Invoke-Test 'an entry excluded before the first block is never touched' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppB' -Command 'C:\B\b.exe'

        $result = Set-StartupGuardSwitch -State On -Exclude 'AppA' -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-True (@($result.Blocked) -notcontains 'AppA') 'The excluded entry was blocked.'
        Assert-True ($null -eq (Get-TestApproval -Name 'AppA' -Variant 'Run')) 'The excluded entry received an overlay.'
        Assert-ApprovalByte -Name 'AppB' -Variant 'Run' -Expected 3

        $status = Get-Status
        Assert-Equal 1 $status.Counts.Excluded
        Assert-Equal 1 $status.Counts.Blocked
        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
    }

    Invoke-Test 'dry run reports the plan without changing anything' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        $result = Set-StartupGuardSwitch -State On -DryRun -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-Equal 'On' $result.RequestedState
        Assert-Equal 'Off' $result.Switch
        Assert-True ($result.DryRun) 'DryRun was not reported.'
        Assert-True (@($result.Blocked) -contains 'AppA') 'The plan did not include AppA.'
        Assert-True ($null -eq (Get-TestApproval -Name 'AppA' -Variant 'Run')) 'Dry run wrote an overlay.'
        Assert-False (Test-Path -LiteralPath $script:StatePath) 'Dry run wrote a state file.'
    }

    Invoke-Test 'off is a no-op when the switch was never used' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        $result = Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-Equal 'Off' $result.Switch
        Assert-Equal 0 @($result.Restored).Count
        Assert-False (Test-Path -LiteralPath $script:StatePath) 'A no-op off wrote a state file.'
    }

    Invoke-Test 'unknown approval values are skipped instead of overwritten' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        $unknown = [byte[]](7, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)
        Set-TestApproval -Name 'AppA' -Variant 'Run' -Bytes $unknown

        $result = Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-True (@($result.Skipped) -contains 'AppA') 'The unknown entry was not skipped.'
        $after = Get-TestApproval -Name 'AppA' -Variant 'Run'
        Assert-Equal ([Convert]::ToBase64String($unknown)) ([Convert]::ToBase64String([byte[]]$after))
        $status = Get-Status
        Assert-Equal 1 $status.Counts.Unknown
        Assert-Equal 'On' $status.Switch
    }

    Invoke-Test 'two entries that share one overlay are blocked and restored once' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'SameName' -Command 'C:\A\a.exe'
        Add-TestRunValue -SourceId 'MachineRun' -Name 'SameName' -Command 'C:\B\b.exe'

        $result = Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-Equal 1 @($result.Blocked).Count
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        Assert-Equal 1 @($state.disabled).Count
        $status = Get-Status
        Assert-Equal 2 $status.Counts.Blocked

        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Assert-True ($null -eq (Get-TestApproval -Name 'SameName' -Variant 'Run')) 'The shared overlay was not removed.'
    }

    Invoke-Test 'off still works when a blocked program was uninstalled' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Remove-TestRunValue -SourceId 'UserRun' -Name 'AppA'

        $off = Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-Equal 0 @($off.Failed).Count
        Assert-Equal 'Off' $off.Switch
        Assert-True ($null -eq (Get-TestApproval -Name 'AppA' -Variant 'Run')) 'The orphaned overlay was not removed.'
    }

    Invoke-Test 'a custom state path is honoured' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        $customState = Join-Path $env:TEMP ('startup-guard-test-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $customState | Out-Null
            Assert-True (Test-Path -LiteralPath $customState) 'The custom state file was not created.'
            $status = Get-StartupGuardStatus -SandboxRoot $script:Sandbox -StatePath $customState
            Assert-Equal 1 $status.Counts.Blocked
            Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $customState | Out-Null
            $offStatus = Get-StartupGuardStatus -SandboxRoot $script:Sandbox -StatePath $customState
            Assert-Equal 'Off' $offStatus.Switch
        }
        finally {
            Remove-Item -LiteralPath $customState -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-Test 'per-entry selection is remembered while the switch is off' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppB' -Command 'C:\B\b.exe'

        $selection = Set-StartupGuardExclusions -Exclude @('AppA') -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-Equal 'Off' $selection.Switch
        Assert-True ($null -eq (Get-TestApproval -Name 'AppA' -Variant 'Run')) 'Selecting while off wrote an overlay.'

        $status = Get-Status
        $entryA = $status.Entries | Where-Object { $_.Name -eq 'AppA' } | Select-Object -First 1
        Assert-Equal 'Excluded' $entryA.DisplayState
        Assert-Equal 1 $status.Counts.Excluded
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        Assert-Equal 'AppA' (@($state.excluded) -join ',')

        Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Assert-True ($null -eq (Get-TestApproval -Name 'AppA' -Variant 'Run')) 'The remembered selection was not respected.'
        Assert-ApprovalByte -Name 'AppB' -Variant 'Run' -Expected 3
        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
    }

    Invoke-Test 'toggling the selection while the switch is on applies immediately' {
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppA' -Command 'C:\A\a.exe'
        Add-TestRunValue -SourceId 'UserRun' -Name 'AppB' -Command 'C:\B\b.exe'
        Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Assert-ApprovalByte -Name 'AppA' -Variant 'Run' -Expected 3
        Assert-ApprovalByte -Name 'AppB' -Variant 'Run' -Expected 3

        $release = Set-StartupGuardExclusions -Exclude @('AppA') -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-Equal 'On' $release.Switch
        Assert-True ($null -eq (Get-TestApproval -Name 'AppA' -Variant 'Run')) 'Unchecking did not release the entry.'
        Assert-ApprovalByte -Name 'AppB' -Variant 'Run' -Expected 3
        $status = Get-Status
        Assert-Equal 1 $status.Counts.Blocked
        Assert-Equal 1 $status.Counts.Excluded

        Set-StartupGuardExclusions -Exclude @() -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        Assert-ApprovalByte -Name 'AppA' -Variant 'Run' -Expected 3
        Assert-ApprovalByte -Name 'AppB' -Variant 'Run' -Expected 3
        Assert-Equal 0 (Get-Status).Counts.Excluded
        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
    }

    Invoke-Test 'Windows system entries are protected from blocking' {
        Add-TestRunValue -SourceId 'MachineRun' -Name 'SecurityHealth' -Command '%windir%\system32\SecurityHealthSystray.exe'
        Add-TestRunValue -SourceId 'UserRun' -Name 'PowerWatch' -Command '%windir%\system32\wscript.exe "E:\PowerWatch\start.vbs" logon'

        $on = Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-True (@($on.Blocked) -notcontains 'SecurityHealth') 'SecurityHealth was blocked.'
        Assert-True (@($on.Blocked) -contains 'PowerWatch') 'A user script launcher was treated as a system entry.'
        Assert-True ($null -eq (Get-TestApproval -Name 'SecurityHealth' -Variant 'Run')) 'SecurityHealth received an overlay.'
        Assert-ApprovalByte -Name 'PowerWatch' -Variant 'Run' -Expected 3

        $status = Get-Status
        $systemEntry = $status.Entries | Where-Object { $_.Name -eq 'SecurityHealth' } | Select-Object -First 1
        Assert-Equal 'Protected' $systemEntry.DisplayState
        Assert-Equal 1 $status.Counts.Protected
        Assert-Equal 1 $status.Counts.Blocked
        Assert-Equal 2 $status.Counts.Total

        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
    }

    Invoke-Test 'an older record that blocked a system entry is released' {
        Add-TestRunValue -SourceId 'MachineRun' -Name 'SecurityHealth' -Command '%windir%\system32\SecurityHealthSystray.exe'
        Set-TestApproval -Name 'SecurityHealth' -Variant 'Run' -Bytes ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        $oldState = [ordered]@{
            version   = 1
            switch    = 'on'
            updatedAt = (Get-Date).ToString('o')
            excluded  = @()
            disabled  = @(
                [ordered]@{ name = 'SecurityHealth'; variant = 'Run'; sourceId = 'MachineRun'; previousKind = 'none'; previousBytes = $null }
            )
        }
        $oldState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8

        $status = Get-Status
        Assert-Equal 'Protected' (($status.Entries | Where-Object { $_.Name -eq 'SecurityHealth' } | Select-Object -First 1).DisplayState)
        Assert-True ((@($status.Warnings) -join ' ') -match 'still disabled') 'The old blocked system entry was not reported.'

        $on = Set-StartupGuardSwitch -State On -SandboxRoot $script:Sandbox -StatePath $script:StatePath
        Assert-True (@($on.ProtectedReleased) -contains 'SecurityHealth') 'The old system record was not released.'
        Assert-True ($null -eq (Get-TestApproval -Name 'SecurityHealth' -Variant 'Run')) 'The system overlay was not removed.'
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        Assert-Equal 'on' $state.switch
        Assert-Equal 0 @($state.disabled).Count

        Set-StartupGuardSwitch -State Off -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
    }

    Invoke-Test 'installer copies runtime files and creates a desktop shortcut' {
        $root = Join-Path $env:TEMP ('sg-install-test-' + [guid]::NewGuid().ToString('N'))
        $installDir = Join-Path $root 'install'
        $desktopDir = Join-Path $root 'desktop'
        New-Item -ItemType Directory -Path $desktopDir -Force | Out-Null
        try {
            $result = & (Join-Path $ModuleRoot 'install.ps1') -SourceDir $ModuleRoot -InstallDir $installDir -DesktopDir $desktopDir -Quiet
            Assert-True ($result.ShortcutCreated) 'The installer did not report a shortcut.'

            foreach ($name in @('StartupGuard.Gui.ps1', 'StartupGuard.psm1', 'startup-guard.ps1', 'startup-guard.cmd', 'README.md')) {
                $path = Join-Path $result.AppDir $name
                Assert-True (Test-Path -LiteralPath $path) "The installer did not copy $name."
            }
            Assert-True (Test-Path -LiteralPath $result.IconPath) 'The installer did not create the icon.'
            $icon = [System.Drawing.Icon]::new($result.IconPath)
            try { Assert-Equal 64 $icon.Width } finally { $icon.Dispose() }

            $shortcuts = @(Get-ChildItem -LiteralPath $desktopDir -Filter '*.lnk' -File)
            Assert-Equal 1 $shortcuts.Count 'Expected exactly one desktop shortcut.'
            $shortcutPath = $shortcuts[0].FullName
            $shell = New-Object -ComObject WScript.Shell
            try {
                $shortcut = $shell.CreateShortcut($shortcutPath)
                Assert-True ($shortcut.TargetPath -like '*powershell.exe') "Unexpected shortcut target: $($shortcut.TargetPath)"
                Assert-True ($shortcut.Arguments -like '*StartupGuard.Gui.ps1*') 'The shortcut does not launch the GUI.'
                Assert-True ($shortcut.IconLocation -like '*StartupGuard.ico*') 'The shortcut has no custom icon.'
                Assert-True ((Test-Path -LiteralPath (Join-Path $result.InstallDir 'state.json')) -eq $false) 'The installer created a state file.'
            }
            finally {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
            }

            $stateFile = Join-Path $result.InstallDir 'state.json'
            Set-Content -LiteralPath $stateFile -Value '{"version":1,"switch":"off"}' -Encoding UTF8
            $null = & (Join-Path $ModuleRoot 'install.ps1') -SourceDir $ModuleRoot -InstallDir $installDir -DesktopDir $desktopDir -Quiet
            $preserved = (Get-Content -LiteralPath $stateFile -Raw).Trim()
            Assert-Equal '{"version":1,"switch":"off"}' $preserved 'Reinstall must not overwrite the switch state file.'
        }
        finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-Test 'legacy null exclusions are ignored and cleaned on save' {
        $legacy = [ordered]@{
            version   = 1
            switch    = 'off'
            updatedAt = (Get-Date).ToString('o')
            excluded  = @($null)
            disabled  = @()
        }
        $legacy | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8

        $status = Get-Status
        Assert-Equal 0 @($status.Excluded).Count
        Assert-Equal 0 $status.Counts.Excluded

        Set-StartupGuardExclusions -Exclude @() -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        $raw = Get-Content -LiteralPath $script:StatePath -Raw
        Assert-False ($raw -match '"excluded":\s*\[\s*null') 'The saved state still contains a null exclusion.'
    }

    Invoke-Test 'a corrupt state file produces a clear error' {
        Set-Content -LiteralPath $script:StatePath -Value 'this is not json'
        $threw = $false
        try {
            Get-StartupGuardStatus -SandboxRoot $script:Sandbox -StatePath $script:StatePath | Out-Null
        }
        catch {
            $threw = $true
            Assert-True ($_.Exception.Message -like '*Cannot read Startup Guard state file*') "Unexpected error: $($_.Exception.Message)"
        }
        Assert-True $threw 'A corrupt state file did not raise an error.'
    }
}
finally {
    try { $script:Registry.DeleteSubKeyTree($script:Sandbox, $false) } catch { }
    if (Test-Path -LiteralPath $script:SandboxDir) {
        Remove-Item -LiteralPath $script:SandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $after = Get-RealApprovalSnapshot
    $before = $script:RealApprovalSnapshot
    $changed = @()
    foreach ($key in @($before.Keys)) {
        if ($after.ContainsKey($key)) {
            if ($after[$key] -ne $before[$key]) { $changed += $key }
        }
        else { $changed += $key }
    }
    foreach ($key in @($after.Keys)) {
        if (-not $before.ContainsKey($key)) { $changed += $key }
    }
    if ($changed.Count -gt 0) {
        $script:Fail++
        $script:Failures.Add('real StartupApproved keys must not change')
        Write-Host ('FAIL  real StartupApproved keys changed: {0}' -f (($changed | Sort-Object) -join ', ')) -ForegroundColor Red
    }
    else {
        Write-Host 'OK    real StartupApproved keys were not touched' -ForegroundColor Green
    }
}

Write-Host ''
if ($script:Fail -gt 0) {
    Write-Host ('{0} passed, {1} failed. Failed: {2}' -f $script:Pass, $script:Fail, ($script:Failures -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host ('{0} passed, 0 failed.' -f $script:Pass) -ForegroundColor Green
exit 0
