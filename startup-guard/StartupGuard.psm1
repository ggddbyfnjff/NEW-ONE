#Requires -Version 5.1
<#
.SYNOPSIS
    Core engine for the Startup Guard boot-request blocker.

.DESCRIPTION
    Startup Guard turns a single switch on or off.  When the switch is on it
    writes per-user StartupApproved markers (the same mechanism Task Manager
    uses) for every entry Windows would launch at sign-in: HKCU/HKLM Run keys,
    the 32-bit Run key and the two Startup folders.  The original approval
    bytes are kept in a small state file so switching the guard off restores
    the previous configuration exactly.

    Nothing here removes Run-key values or shortcut files; the overlay is
    per-user, reversible and needs no administrator rights.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GuardVersion = 1
$script:RunKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunKeyPath32 = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
$script:ApprovalKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Get-StartupGuardDefaultStatePath {
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:USERPROFILE }
    return (Join-Path $base 'StartupGuard\state.json')
}

function Get-StartupGuardPaths {
    <#
        Returns every registry/file location the engine reads or writes.
        -SandboxRoot is a test-only option: a subkey path below HKCU.  When it
        is set, no real startup location is touched.
    #>
    [CmdletBinding()]
    param(
        [string]$SandboxRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($SandboxRoot)) {
        $sandboxRoot = $SandboxRoot.Trim('\')
        $leaf = ($sandboxRoot -split '[\\/]')[-1]
        $sandboxDir = Join-Path $env:TEMP (Join-Path 'StartupGuardTests' $leaf)
        return [pscustomobject]@{
            IsSandbox      = $true
            SandboxRoot    = $sandboxRoot
            StatePath      = (Join-Path $sandboxDir 'state.json')
            Sources        = @(
                [pscustomobject]@{ Id = 'UserRun';         Hive = 'HKCU'; SubKey = (Join-Path $sandboxRoot 'HKCU\Run');   Variant = 'Run';  Label = 'HKCU Run' }
                [pscustomobject]@{ Id = 'MachineRun';      Hive = 'HKCU'; SubKey = (Join-Path $sandboxRoot 'HKLM\Run');   Variant = 'Run';  Label = 'HKLM Run' }
                [pscustomobject]@{ Id = 'MachineRun32';    Hive = 'HKCU'; SubKey = (Join-Path $sandboxRoot 'HKLM\Run32'); Variant = 'Run32'; Label = 'HKLM Run (32-bit)' }
            )
            ApprovalHive   = 'HKCU'
            ApprovalSubKey = (Join-Path $sandboxRoot 'Approved')
            StartupFolders = @(
                [pscustomobject]@{ Id = 'UserStartupFolder';   Path = (Join-Path $sandboxDir 'Startup\User');   Label = 'User startup folder' }
                [pscustomobject]@{ Id = 'CommonStartupFolder'; Path = (Join-Path $sandboxDir 'Startup\Common'); Label = 'Common startup folder' }
            )
        }
    }

    $userStartup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $commonBase = $env:ProgramData
    $commonStartup = if ([string]::IsNullOrWhiteSpace($commonBase)) { $null } else { Join-Path $commonBase 'Microsoft\Windows\Start Menu\Programs\StartUp' }

    return [pscustomobject]@{
        IsSandbox      = $false
        SandboxRoot    = ''
        StatePath      = (Get-StartupGuardDefaultStatePath)
        Sources        = @(
            [pscustomobject]@{ Id = 'UserRun';      Hive = 'HKCU'; SubKey = $script:RunKeyPath;   Variant = 'Run';   Label = 'HKCU Run' }
            [pscustomobject]@{ Id = 'MachineRun';   Hive = 'HKLM'; SubKey = $script:RunKeyPath;   Variant = 'Run';   Label = 'HKLM Run' }
            [pscustomobject]@{ Id = 'MachineRun32'; Hive = 'HKLM'; SubKey = $script:RunKeyPath32; Variant = 'Run32'; Label = 'HKLM Run (32-bit)' }
        )
        ApprovalHive   = 'HKCU'
        ApprovalSubKey = $script:ApprovalKeyPath
        StartupFolders = @(
            [pscustomobject]@{ Id = 'UserStartupFolder';   Path = $userStartup;   Label = 'User startup folder' }
            [pscustomobject]@{ Id = 'CommonStartupFolder'; Path = $commonStartup; Label = 'Common startup folder' }
        )
    }
}

function Get-StartupGuardHive {
    param([string]$Name)
    switch ($Name) {
        'HKCU' { return [Microsoft.Win32.Registry]::CurrentUser }
        'HKLM' { return [Microsoft.Win32.Registry]::LocalMachine }
        default { throw "Unknown registry hive: $Name" }
    }
}

function Get-StartupGuardKey {
    param([string]$Name, [string]$Variant)
    return ('{0}|{1}' -f $Variant, $Name).ToLowerInvariant()
}

function Get-StartupGuardCommandPath {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Command).Trim()

    if ($expanded.StartsWith('"')) {
        $closingQuote = $expanded.IndexOf('"', 1)
        if ($closingQuote -gt 1) { return $expanded.Substring(1, $closingQuote - 1).Trim() }
    }

    $match = [regex]::Match($expanded, '^(.+?\.(exe|com|bat|cmd|vbs|ps1|dll))(\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) { return $match.Groups[1].Value.Trim('"') }
    return ($expanded.Split([char[]]@(' ', "`t"), 2)[0]).Trim('"')
}

function Test-StartupGuardSystemEntry {
    param([string]$Name, [string]$Command)

    # Windows Security and Defender are never treated as removable startup apps.
    if (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -match '^(SecurityHealth|Windows ?Defender|Windows Security)') {
        return $true
    }

    $path = Get-StartupGuardCommandPath -Command $Command
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }

    # wscript/cscript and shell hosts launch a user script, not a system component.
    $leaf = [System.IO.Path]::GetFileName($path)
    if (@('wscript.exe', 'cscript.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe') -contains $leaf.ToLowerInvariant()) {
        return $false
    }

    $systemRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { $systemRoot = 'C:\Windows' }
    $fullPath = $path
    try {
        if (-not [System.IO.Path]::IsPathRooted($fullPath)) {
            $fullPath = [System.IO.Path]::GetFullPath($fullPath)
        }
    }
    catch { return $false }

    if ($fullPath.StartsWith(($systemRoot.TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $programFiles = $env:ProgramFiles
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $defenderPrefix = $programFiles.TrimEnd('\') + '\Windows Defender\'
        if ($fullPath.StartsWith($defenderPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-StartupGuardExcluded {
    param([string]$Name, [string[]]$Patterns)
    foreach ($pattern in @($Patterns)) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $Name -like $pattern) {
            return $true
        }
    }
    return $false
}

function Get-StartupGuardApproval {
    param($Paths, [string]$Name, [string]$Variant)

    $subKey = '{0}\{1}' -f $Paths.ApprovalSubKey, $Variant
    $key = (Get-StartupGuardHive $Paths.ApprovalHive).OpenSubKey($subKey, $false)
    if ($null -eq $key) {
        return [pscustomobject]@{ Exists = $false; State = 'Enabled'; Bytes = $null }
    }

    try {
        $actualName = $null
        foreach ($candidate in $key.GetValueNames()) {
            if ($candidate -eq $Name) { $actualName = $candidate; break }
        }
        if ($null -eq $actualName) {
            return [pscustomobject]@{ Exists = $false; State = 'Enabled'; Bytes = $null }
        }

        $raw = $key.GetValue($actualName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($raw -isnot [byte[]] -or $raw.Length -lt 1) {
            return [pscustomobject]@{ Exists = $true; State = 'Unknown'; Bytes = $raw }
        }

        $state = switch ($raw[0]) {
            2 { 'Enabled' }
            3 { 'Disabled' }
            default { 'Unknown' }
        }
        return [pscustomobject]@{ Exists = $true; State = $state; Bytes = $raw }
    }
    finally {
        $key.Close()
    }
}

function Set-StartupGuardApproval {
    param($Paths, [string]$Name, [string]$Variant, [byte[]]$Bytes)

    $subKey = '{0}\{1}' -f $Paths.ApprovalSubKey, $Variant
    $key = (Get-StartupGuardHive $Paths.ApprovalHive).CreateSubKey($subKey)
    if ($null -eq $key) { throw "Cannot open registry key for writing: $($Paths.ApprovalHive):\$subKey" }
    try {
        $key.SetValue($Name, [byte[]]$Bytes, [Microsoft.Win32.RegistryValueKind]::Binary)
    }
    finally {
        $key.Close()
    }
}

function Remove-StartupGuardApproval {
    param($Paths, [string]$Name, [string]$Variant)

    $subKey = '{0}\{1}' -f $Paths.ApprovalSubKey, $Variant
    $key = (Get-StartupGuardHive $Paths.ApprovalHive).OpenSubKey($subKey, $true)
    if ($null -eq $key) { return }
    try {
        $key.DeleteValue($Name, $false)
    }
    finally {
        $key.Close()
    }
}

function New-StartupGuardMarker {
    param([byte]$Status)

    $bytes = New-Object byte[] 12
    $bytes[0] = $Status
    $timestamp = [BitConverter]::GetBytes([long][DateTime]::UtcNow.ToFileTimeUtc())
    [Array]::Copy($timestamp, 0, $bytes, 4, 8)
    return ,$bytes
}

function Get-StartupGuardEntryInternal {
    param($Paths)

    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($source in @($Paths.Sources)) {
        $hive = Get-StartupGuardHive $source.Hive
        $key = $hive.OpenSubKey($source.SubKey, $false)
        if ($null -eq $key) { continue }
        try {
            foreach ($valueName in $key.GetValueNames()) {
                if ([string]::IsNullOrEmpty($valueName)) { continue }
                $value = $key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -eq $value) { continue }
                $approval = Get-StartupGuardApproval -Paths $Paths -Name $valueName -Variant $source.Variant
                $bytesBase64 = $null
                if ($null -ne $approval.Bytes -and $approval.Bytes -is [byte[]]) {
                    $bytesBase64 = [Convert]::ToBase64String([byte[]]$approval.Bytes)
                }
                $entries.Add([pscustomobject]@{
                    Name           = $valueName
                    Command        = [string]$value
                    SourceId       = $source.Id
                    Source         = $source.Label
                    Variant        = $source.Variant
                    ApprovalState  = $approval.State
                    HasApproval    = [bool]$approval.Exists
                    PreviousBytes  = $bytesBase64
                    Protected      = (Test-StartupGuardSystemEntry -Name $valueName -Command ([string]$value))
                })
            }
        }
        finally {
            $key.Close()
        }
    }

    $shortcutShell = $null
    try { $shortcutShell = New-Object -ComObject WScript.Shell } catch { $shortcutShell = $null }

    try {
        foreach ($folder in @($Paths.StartupFolders)) {
            if ([string]::IsNullOrWhiteSpace($folder.Path)) { continue }
            if (-not (Test-Path -LiteralPath $folder.Path)) { continue }
            $files = @(Get-ChildItem -LiteralPath $folder.Path -Filter '*.lnk' -File -Force -ErrorAction SilentlyContinue)
            foreach ($file in $files) {
                $command = $file.FullName
                if ($null -ne $shortcutShell) {
                    try {
                        $shortcut = $shortcutShell.CreateShortcut($file.FullName)
                        $target = [string]$shortcut.TargetPath
                        $arguments = [string]$shortcut.Arguments
                        if (-not [string]::IsNullOrWhiteSpace($target)) {
                            $command = if ([string]::IsNullOrWhiteSpace($arguments)) { $target } else { "$target $arguments" }
                        }
                    }
                    catch { $command = $file.FullName }
                }
                $approval = Get-StartupGuardApproval -Paths $Paths -Name $file.Name -Variant 'StartupFolder'
                $bytesBase64 = $null
                if ($null -ne $approval.Bytes -and $approval.Bytes -is [byte[]]) {
                    $bytesBase64 = [Convert]::ToBase64String([byte[]]$approval.Bytes)
                }
                $entries.Add([pscustomobject]@{
                    Name           = $file.Name
                    Command        = $command
                    SourceId       = $folder.Id
                    Source         = $folder.Label
                    Variant        = 'StartupFolder'
                    ApprovalState  = $approval.State
                    HasApproval    = [bool]$approval.Exists
                    PreviousBytes  = $bytesBase64
                    Protected      = (Test-StartupGuardSystemEntry -Name $file.Name -Command $command)
                })
            }
        }
    }
    finally {
        if ($null -ne $shortcutShell) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcutShell) } catch { }
        }
    }

    return $entries.ToArray()
}

function Get-StartupGuardEntry {
    [CmdletBinding()]
    param([string]$SandboxRoot = '')

    $paths = Get-StartupGuardPaths -SandboxRoot $SandboxRoot
    return @(Get-StartupGuardEntryInternal -Paths $paths)
}

function New-StartupGuardEmptyState {
    param([string]$Path)
    return [pscustomobject]@{
        Version   = $script:GuardVersion
        Path      = $Path
        Switch    = 'Off'
        UpdatedAt = $null
        Excluded  = @()
        Disabled  = @()
    }
}

function Get-StartupGuardState {
    param([string]$StatePath = '', [string]$DefaultPath = '')

    $path = if (-not [string]::IsNullOrWhiteSpace($StatePath)) { $StatePath } else { $DefaultPath }
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'No state file path was supplied.' }
    if (-not (Test-Path -LiteralPath $path)) { return (New-StartupGuardEmptyState -Path $path) }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'the file is empty' }
        $obj = $raw | ConvertFrom-Json
    }
    catch {
        throw "Cannot read Startup Guard state file '$path': $($_.Exception.Message)"
    }
    if ($null -eq $obj -or $obj -isnot [pscustomobject]) {
        throw "Startup Guard state file '$path' does not contain a JSON object."
    }

    $switchProperty = $obj.PSObject.Properties['switch']
    $switchValue = 'Off'
    if ($null -ne $switchProperty -and ([string]$switchProperty.Value).ToLowerInvariant() -eq 'on') {
        $switchValue = 'On'
    }

    $excluded = @()
    $excludedProperty = $obj.PSObject.Properties['excluded']
    if ($null -ne $excludedProperty -and $null -ne $excludedProperty.Value) {
        $excluded = @($excludedProperty.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }

    $disabled = New-Object System.Collections.Generic.List[object]
    $disabledProperty = $obj.PSObject.Properties['disabled']
    if ($null -ne $disabledProperty -and $null -ne $disabledProperty.Value) {
        foreach ($item in @($disabledProperty.Value)) {
            if ($null -eq $item) { continue }
            if ([string]::IsNullOrEmpty([string]$item.name)) { continue }
            $variant = [string]$item.variant
            if ([string]::IsNullOrWhiteSpace($variant)) { $variant = 'Run' }
            $previousKind = [string]$item.previousKind
            $previousBytes = [string]$item.previousBytes
            if ($previousKind -ne 'bytes' -or [string]::IsNullOrWhiteSpace($previousBytes)) {
                $previousKind = 'none'
                $previousBytes = $null
            }
            $sourceId = [string]$item.sourceId
            $disabled.Add([pscustomobject]@{
                Name          = [string]$item.name
                Variant       = $variant
                SourceId      = $sourceId
                PreviousKind  = $previousKind
                PreviousBytes = $previousBytes
            })
        }
    }

    $updatedAt = $null
    $updatedProperty = $obj.PSObject.Properties['updatedAt']
    if ($null -ne $updatedProperty) { $updatedAt = $updatedProperty.Value }

    return [pscustomobject]@{
        Version   = $script:GuardVersion
        Path      = $path
        Switch    = $switchValue
        UpdatedAt = $updatedAt
        Excluded  = $excluded
        Disabled  = $disabled.ToArray()
    }
}

function Save-StartupGuardState {
    param($State)

    $path = $State.Path
    $directory = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $payload = [ordered]@{
        version   = $script:GuardVersion
        switch    = if ($State.Switch -eq 'On') { 'on' } else { 'off' }
        updatedAt = $State.UpdatedAt
        excluded  = @($State.Excluded | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        disabled  = @(
            foreach ($record in @($State.Disabled)) {
                [ordered]@{
                    name          = $record.Name
                    variant       = $record.Variant
                    sourceId      = $record.SourceId
                    previousKind  = $record.PreviousKind
                    previousBytes = $record.PreviousBytes
                }
            }
        )
    }

    $json = ConvertTo-Json -InputObject $payload -Depth 8
    $temporaryPath = "$path.tmp"
    [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}

function Restore-StartupGuardRecord {
    param($Paths, $Record)

    if ($Record.PreviousKind -eq 'bytes') {
        $bytes = [Convert]::FromBase64String($Record.PreviousBytes)
        Set-StartupGuardApproval -Paths $Paths -Name $Record.Name -Variant $Record.Variant -Bytes $bytes
        $check = Get-StartupGuardApproval -Paths $Paths -Name $Record.Name -Variant $Record.Variant
        if (-not $check.Exists -or $null -eq $check.Bytes) { return $false }
        return ([Convert]::ToBase64String([byte[]]$check.Bytes) -eq $Record.PreviousBytes)
    }

    Remove-StartupGuardApproval -Paths $Paths -Name $Record.Name -Variant $Record.Variant
    $check = Get-StartupGuardApproval -Paths $Paths -Name $Record.Name -Variant $Record.Variant
    return (-not $check.Exists)
}

function Set-StartupGuardBlocked {
    param($Paths, [string]$Name, [string]$Variant)

    $marker = New-StartupGuardMarker -Status 3
    Set-StartupGuardApproval -Paths $Paths -Name $Name -Variant $Variant -Bytes $marker
    $check = Get-StartupGuardApproval -Paths $Paths -Name $Name -Variant $Variant
    return ($check.State -eq 'Disabled')
}

function Get-StartupGuardStatus {
    <#
        Returns the current switch state plus every startup entry and how the
        guard sees it: Blocked, Disabled, Excluded, Protected, Enabled or
        Unknown.
    #>
    [CmdletBinding()]
    param(
        [string]$SandboxRoot = '',
        [string]$StatePath = ''
    )

    $paths = Get-StartupGuardPaths -SandboxRoot $SandboxRoot
    $state = Get-StartupGuardState -StatePath $StatePath -DefaultPath $paths.StatePath

    $recorded = @{}
    foreach ($record in @($state.Disabled)) {
        $recorded[(Get-StartupGuardKey -Name $record.Name -Variant $record.Variant)] = $true
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $systemBlocked = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-StartupGuardEntryInternal -Paths $paths)) {
        $key = Get-StartupGuardKey -Name $entry.Name -Variant $entry.Variant
        $isRecorded = $recorded.ContainsKey($key)
        $isProtected = [bool]$entry.Protected
        $isExcluded = Test-StartupGuardExcluded -Name $entry.Name -Patterns $state.Excluded
        if ($isProtected -and $entry.ApprovalState -eq 'Disabled' -and $isRecorded) {
            $systemBlocked.Add($entry.Name)
        }
        $displayState = if ($isProtected) {
            'Protected'
        }
        else {
            switch ($entry.ApprovalState) {
                'Disabled' {
                    if ($isRecorded) { 'Blocked' } else { 'Disabled' }
                }
                'Unknown' { 'Unknown' }
                default {
                    if ($isExcluded) { 'Excluded' } else { 'Enabled' }
                }
            }
        }
        $entries.Add([pscustomobject]@{
            Name          = $entry.Name
            Command       = $entry.Command
            SourceId      = $entry.SourceId
            Source        = $entry.Source
            Variant       = $entry.Variant
            ApprovalState = $entry.ApprovalState
            DisplayState  = $displayState
            IsRecorded    = $isRecorded
            Protected     = $isProtected
            IsExcluded    = $isExcluded
        })
    }

    $entryArray = $entries.ToArray()
    $counts = [pscustomobject]@{
        Total    = $entryArray.Count
        Blocked  = @($entryArray | Where-Object { $_.DisplayState -eq 'Blocked' }).Count
        Enabled  = @($entryArray | Where-Object { $_.DisplayState -eq 'Enabled' }).Count
        Disabled = @($entryArray | Where-Object { $_.DisplayState -eq 'Disabled' }).Count
        Excluded = @($entryArray | Where-Object { $_.DisplayState -eq 'Excluded' }).Count
        Protected = @($entryArray | Where-Object { $_.DisplayState -eq 'Protected' }).Count
        Unknown  = @($entryArray | Where-Object { $_.DisplayState -eq 'Unknown' }).Count
    }

    $drift = @()
    if ($state.Switch -eq 'On') {
        $drift = @($entryArray | Where-Object { $_.DisplayState -eq 'Enabled' } | ForEach-Object { $_.Name })
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    if ($counts.Unknown -gt 0) {
        $warnings.Add("$($counts.Unknown) startup entr$(if ($counts.Unknown -eq 1) { 'y has' } else { 'ies have' }) an unrecognized StartupApproved state and were left alone.")
    }
    if ($state.Switch -eq 'Off' -and @($state.Disabled).Count -gt 0) {
        $warnings.Add("The state file is off but still records $(@($state.Disabled).Count) blocked entr$(if (@($state.Disabled).Count -eq 1) { 'y' } else { 'ies' }). Run off again to restore them.")
    }
    foreach ($name in $systemBlocked) {
        $warnings.Add("System entry '$name' is still disabled by an older record; run on or off to release it.")
    }

    return [pscustomobject]@{
        Switch    = $state.Switch
        Entries   = $entryArray
        Counts    = $counts
        Drift     = $drift
        Warnings  = $warnings.ToArray()
        Excluded  = @($state.Excluded)
        StatePath = $state.Path
        UpdatedAt = $state.UpdatedAt
        IsSandbox = [bool]$paths.IsSandbox
    }
}

function Set-StartupGuardSwitch {
    <#
        Turns the guard switch on or off.

        On  - blocks every enabled startup entry that is not excluded, records
              the previous approval bytes for an exact later restore and
              re-applies the block to recorded entries that drift back on.
        Off - restores every recorded entry and clears the switch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('On', 'Off')]
        [string]$State,
        [string[]]$Exclude,
        [switch]$DryRun,
        [string]$SandboxRoot = '',
        [string]$StatePath = ''
    )

    $paths = Get-StartupGuardPaths -SandboxRoot $SandboxRoot
    $guardState = Get-StartupGuardState -StatePath $StatePath -DefaultPath $paths.StatePath
    $excludeProvided = $PSBoundParameters.ContainsKey('Exclude')
    $excluded = if ($excludeProvided) { @($Exclude | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ }) } else { @($guardState.Excluded) }

    $result = [pscustomobject]@{
        RequestedState     = $State
        Switch             = $guardState.Switch
        DryRun             = [bool]$DryRun
        Blocked            = @()
        Reapplied          = @()
        Restored           = @()
        ExclusionsRestored = @()
        ProtectedReleased  = @()
        Failed             = @()
        Warnings           = @()
        Skipped            = @()
        Counts             = $null
    }

    if ($State -eq 'On') {
        $entryList = @(Get-StartupGuardEntryInternal -Paths $paths)
        $entryByKey = @{}
        foreach ($entry in $entryList) {
            $entryByKey[(Get-StartupGuardKey -Name $entry.Name -Variant $entry.Variant)] = $entry
        }

        # Exclusions and built-in system protection always win: release any
        # entries blocked by an older version or by a previous exclusion list.
        $remaining = New-Object System.Collections.Generic.List[object]
        foreach ($record in @($guardState.Disabled)) {
            $recordKey = Get-StartupGuardKey -Name $record.Name -Variant $record.Variant
            $releaseReason = $null
            if (Test-StartupGuardExcluded -Name $record.Name -Patterns $excluded) {
                $releaseReason = 'excluded'
            }
            elseif ($entryByKey.ContainsKey($recordKey) -and $entryByKey[$recordKey].Protected) {
                $releaseReason = 'system'
            }
            elseif (-not $entryByKey.ContainsKey($recordKey) -and (Test-StartupGuardSystemEntry -Name $record.Name -Command '')) {
                $releaseReason = 'system'
            }

            if ($null -eq $releaseReason) {
                $remaining.Add($record)
                continue
            }

            if ($DryRun) {
                if ($releaseReason -eq 'system') { $result.ProtectedReleased += $record.Name }
                else { $result.ExclusionsRestored += $record.Name }
                $remaining.Add($record)
                continue
            }

            try {
                if (Restore-StartupGuardRecord -Paths $paths -Record $record) {
                    if ($releaseReason -eq 'system') { $result.ProtectedReleased += $record.Name }
                    else { $result.ExclusionsRestored += $record.Name }
                }
                else {
                    $remaining.Add($record)
                    $result.Failed += "Could not release $(if ($releaseReason -eq 'system') { 'system' } else { 'excluded' }) entry '$($record.Name)'."
                }
            }
            catch {
                $remaining.Add($record)
                $result.Failed += "Could not release $(if ($releaseReason -eq 'system') { 'system' } else { 'excluded' }) entry '$($record.Name)': $($_.Exception.Message)"
            }
        }
        if (-not $DryRun) { $guardState.Disabled = $remaining.ToArray() }

        $recorded = @{}
        foreach ($record in @($guardState.Disabled)) {
            $recorded[(Get-StartupGuardKey -Name $record.Name -Variant $record.Variant)] = $record
        }

        $planned = @{}
        foreach ($entry in $entryList) {
            if ($entry.Protected) { continue }
            if (Test-StartupGuardExcluded -Name $entry.Name -Patterns $excluded) { continue }

            $key = Get-StartupGuardKey -Name $entry.Name -Variant $entry.Variant
            switch ($entry.ApprovalState) {
                'Unknown' {
                    $result.Skipped += $entry.Name
                    $result.Warnings += "Skipped '$($entry.Name)' because its StartupApproved value is not recognized."
                }
                'Disabled' {
                    # Already blocked (by the guard or by the user); nothing to do.
                }
                'Enabled' {
                    if ($planned.ContainsKey($key)) { continue }
                    if ($recorded.ContainsKey($key)) {
                        $planned[$key] = [pscustomobject]@{ Entry = $entry; Kind = 'Reapply'; Record = $recorded[$key] }
                    }
                    else {
                        $previousKind = 'none'
                        if ($entry.HasApproval -and -not [string]::IsNullOrWhiteSpace($entry.PreviousBytes)) {
                            $previousKind = 'bytes'
                        }
                        $record = [pscustomobject]@{
                            Name          = $entry.Name
                            Variant       = $entry.Variant
                            SourceId      = $entry.SourceId
                            PreviousKind  = $previousKind
                            PreviousBytes = if ($previousKind -eq 'bytes') { $entry.PreviousBytes } else { $null }
                        }
                        $planned[$key] = [pscustomobject]@{ Entry = $entry; Kind = 'Block'; Record = $record }
                    }
                }
            }
        }

        foreach ($action in $planned.Values) {
            if ($action.Kind -eq 'Block') { $guardState.Disabled = @($guardState.Disabled) + @($action.Record) }
        }

        if (-not $DryRun) {
            $guardState.Switch = 'On'
            $guardState.Excluded = $excluded
            $guardState.UpdatedAt = (Get-Date).ToString('o')
            Save-StartupGuardState -State $guardState
        }

        $failedRecords = New-Object System.Collections.Generic.List[object]
        foreach ($action in $planned.Values) {
            $entry = $action.Entry
            if ($DryRun) {
                if ($action.Kind -eq 'Block') { $result.Blocked += $entry.Name } else { $result.Reapplied += $entry.Name }
                continue
            }
            try {
                if (-not (Set-StartupGuardBlocked -Paths $paths -Name $entry.Name -Variant $entry.Variant)) {
                    throw 'the StartupApproved value did not read back as disabled'
                }
                if ($action.Kind -eq 'Block') { $result.Blocked += $entry.Name } else { $result.Reapplied += $entry.Name }
            }
            catch {
                $result.Failed += "Could not block '$($entry.Name)': $($_.Exception.Message)"
                if ($action.Kind -eq 'Block') { $failedRecords.Add($action.Record) }
            }
        }

        if (-not $DryRun -and $failedRecords.Count -gt 0) {
            $failedKeys = @($failedRecords | ForEach-Object { Get-StartupGuardKey -Name $_.Name -Variant $_.Variant })
            $guardState.Disabled = @($guardState.Disabled | Where-Object { $failedKeys -notcontains (Get-StartupGuardKey -Name $_.Name -Variant $_.Variant) })
            $guardState.UpdatedAt = (Get-Date).ToString('o')
            Save-StartupGuardState -State $guardState
        }
    }
    else {
        $hadRestoreRecords = @($guardState.Disabled).Count -gt 0
        $wasOn = $guardState.Switch -eq 'On'
        $remaining = New-Object System.Collections.Generic.List[object]
        foreach ($record in @($guardState.Disabled)) {
            if ($DryRun) {
                $result.Restored += $record.Name
                continue
            }
            try {
                if (Restore-StartupGuardRecord -Paths $paths -Record $record) {
                    $result.Restored += $record.Name
                }
                else {
                    $remaining.Add($record)
                    $result.Failed += "Could not restore '$($record.Name)'."
                }
            }
            catch {
                $remaining.Add($record)
                $result.Failed += "Could not restore '$($record.Name)': $($_.Exception.Message)"
            }
        }

        if (-not $DryRun -and ($hadRestoreRecords -or $wasOn)) {
            $guardState.Disabled = $remaining.ToArray()
            if ($remaining.Count -eq 0) { $guardState.Switch = 'Off' }
            else {
                $guardState.Switch = 'On'
                $result.Warnings += 'Some entries could not be restored; the switch remains on so they can be retried.'
            }
            $guardState.UpdatedAt = (Get-Date).ToString('o')
            Save-StartupGuardState -State $guardState
        }
    }

    $status = Get-StartupGuardStatus -SandboxRoot $SandboxRoot -StatePath $StatePath
    $result.Switch = $status.Switch
    $result.Counts = $status.Counts
    return $result
}

function Set-StartupGuardExclusions {
    <#
        Replaces the user's exclusion/selection list without changing the
        master switch state. If the switch is on, the change is applied
        immediately: new selections are blocked and newly excluded entries are
        released. If the switch is off, the selection is only remembered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Exclude,
        [string]$SandboxRoot = '',
        [string]$StatePath = ''
    )

    $paths = Get-StartupGuardPaths -SandboxRoot $SandboxRoot
    $state = Get-StartupGuardState -StatePath $StatePath -DefaultPath $paths.StatePath
    $excluded = @($Exclude | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $state.Excluded = $excluded
    $state.UpdatedAt = (Get-Date).ToString('o')
    Save-StartupGuardState -State $state

    if ($state.Switch -eq 'On') {
        return Set-StartupGuardSwitch -State On -Exclude $excluded -SandboxRoot $SandboxRoot -StatePath $StatePath
    }
    return Get-StartupGuardStatus -SandboxRoot $SandboxRoot -StatePath $StatePath
}

Export-ModuleMember -Function @(
    'Get-StartupGuardPaths'
    'Get-StartupGuardEntry'
    'Get-StartupGuardStatus'
    'Set-StartupGuardSwitch'
    'Set-StartupGuardExclusions'
)
