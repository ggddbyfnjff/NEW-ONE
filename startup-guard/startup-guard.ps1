#Requires -Version 5.1
<#
.SYNOPSIS
    Command-line interface for Startup Guard.

.DESCRIPTION
    status   Show the switch state and every startup entry.
    list     Show only the startup entries.
    on       Turn the switch on: block all enabled startup entries.
    off      Turn the switch off: restore everything the switch blocked.
    gui      Open the desktop switch window.

    -DryRun  Show what on/off would do without changing anything.
    -Json    Emit machine-readable JSON instead of a table.

    Test/advanced options: -SandboxRoot and -StatePath.  When -SandboxRoot is
    set, all reads and writes stay inside a disposable HKCU test key and a
    temporary folder; nothing real is touched.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'list', 'on', 'off', 'gui')]
    [string]$Command = 'status',

    [string[]]$Exclude,
    [switch]$DryRun,
    [switch]$Json,
    [string]$SandboxRoot = '',
    [string]$StatePath = ''
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'StartupGuard.psm1'
Import-Module $modulePath -Force

function Limit-GuardText {
    param([string]$Text, [int]$MaxLength)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, $MaxLength - 3) + '...'
}

function Write-GuardStatusText {
    param($Status, [switch]$EntriesOnly)

    if (-not $EntriesOnly) {
        Write-Output ('Startup Guard switch : {0}' -f $Status.Switch.ToUpperInvariant())
        Write-Output ('Blocked by guard     : {0}' -f $Status.Counts.Blocked)
        Write-Output ('Startup entries      : {0} total | {1} enabled | {2} disabled | {3} excluded | {4} protected | {5} unknown' -f `
            $Status.Counts.Total, $Status.Counts.Enabled, $Status.Counts.Disabled, $Status.Counts.Excluded, $Status.Counts.Protected, $Status.Counts.Unknown)
        if ($Status.Drift.Count -gt 0) {
            Write-Output ('Not blocked          : {0} ({1}) - run "on" to re-apply' -f $Status.Drift.Count, ($Status.Drift -join ', '))
        }
        Write-Output ('State file           : {0}' -f $Status.StatePath)
        if ($Status.Warnings.Count -gt 0) {
            foreach ($warning in $Status.Warnings) { Write-Output ('Warning              : {0}' -f $warning) }
        }
        Write-Output ''
    }

    if ($Status.Entries.Count -eq 0) {
        Write-Output 'No startup entries were found.'
        return
    }

    Write-Output ('{0,-11} {1,-34} {2,-24} {3}' -f 'STATE', 'NAME', 'SOURCE', 'COMMAND')
    Write-Output ('{0,-11} {1,-34} {2,-24} {3}' -f ('-' * 11), ('-' * 34), ('-' * 24), ('-' * 40))
    foreach ($entry in $Status.Entries) {
        Write-Output ('{0,-11} {1,-34} {2,-24} {3}' -f `
            $entry.DisplayState,
            (Limit-GuardText $entry.Name 34),
            (Limit-GuardText $entry.Source 24),
            (Limit-GuardText $entry.Command 64))
    }
}

function Write-GuardResultText {
    param($Result)

    $prefix = if ($Result.DryRun) { '[dry run] ' } else { '' }
    Write-Output ('{0}Startup Guard switch is now {1}.' -f $prefix, $Result.Switch.ToUpperInvariant())

    foreach ($entryName in @($Result.Blocked)) { Write-Output ('  blocked        {0}' -f $entryName) }
    foreach ($entryName in @($Result.Reapplied)) { Write-Output ('  re-applied     {0}' -f $entryName) }
    foreach ($entryName in @($Result.Restored)) { Write-Output ('  restored       {0}' -f $entryName) }
    foreach ($entryName in @($Result.ExclusionsRestored)) { Write-Output ('  released       {0} (excluded)' -f $entryName) }
    foreach ($entryName in @($Result.ProtectedReleased)) { Write-Output ('  released       {0} (system)' -f $entryName) }
    foreach ($entryName in @($Result.Skipped)) { Write-Output ('  skipped        {0} (unknown state)' -f $entryName) }
    foreach ($failure in @($Result.Failed)) { Write-Output ('  FAILED         {0}' -f $failure) }
    foreach ($warning in @($Result.Warnings)) { Write-Output ('  warning        {0}' -f $warning) }

    if ($null -ne $Result.Counts) {
        Write-Output ('Entries: {0} total | {1} blocked | {2} enabled | {3} excluded | {4} protected' -f `
            $Result.Counts.Total, $Result.Counts.Blocked, $Result.Counts.Enabled, $Result.Counts.Excluded, $Result.Counts.Protected)
    }
}

try {
    switch ($Command) {
        'gui' {
            $guiPath = Join-Path $PSScriptRoot 'StartupGuard.Gui.ps1'
            & $guiPath -SandboxRoot $SandboxRoot -StatePath $StatePath
            break
        }

        'status' {
            $status = Get-StartupGuardStatus -SandboxRoot $SandboxRoot -StatePath $StatePath
            if ($Json) { $status | ConvertTo-Json -Depth 8 } else { Write-GuardStatusText -Status $status }
            break
        }

        'list' {
            $status = Get-StartupGuardStatus -SandboxRoot $SandboxRoot -StatePath $StatePath
            if ($Json) { $status.Entries | ConvertTo-Json -Depth 8 } else { Write-GuardStatusText -Status $status -EntriesOnly }
            break
        }

        'on' {
            $arguments = @{
                State       = 'On'
                DryRun      = [bool]$DryRun
                SandboxRoot = $SandboxRoot
                StatePath   = $StatePath
            }
            if ($PSBoundParameters.ContainsKey('Exclude')) { $arguments['Exclude'] = $Exclude }
            $result = Set-StartupGuardSwitch @arguments
            if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-GuardResultText -Result $result }
            if (@($result.Failed).Count -gt 0) { exit 2 }
            break
        }

        'off' {
            $result = Set-StartupGuardSwitch -State 'Off' -DryRun:$DryRun -SandboxRoot $SandboxRoot -StatePath $StatePath
            if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-GuardResultText -Result $result }
            if (@($result.Failed).Count -gt 0) { exit 2 }
            break
        }
    }
}
catch {
    Write-Error ('Startup Guard: {0}' -f $_.Exception.Message)
    exit 1
}
