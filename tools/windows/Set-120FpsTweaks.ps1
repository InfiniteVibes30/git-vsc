<#
.SYNOPSIS
    Applies safe, reversible Windows settings that help games reach a steady 120 FPS.

.DESCRIPTION
    Sets Hardware-accelerated GPU scheduling, Game Mode, disables background Game DVR
    recording, enables windowed-game flip-model optimizations, optionally pins a game
    executable to the high-performance GPU, and switches to the High performance power plan.

    Before changing anything it creates a System Restore point (when System Protection is
    enabled), exports every touched registry key to a .reg file, and records the original
    values in state.json so -Revert restores exactly what was there before.

    See docs/120fps-guide.md for what each setting does.

.PARAMETER GameExe
    Optional full path to a game executable to run on the high-performance GPU.

.PARAMETER BackupRoot
    Folder where timestamped backups are written. Defaults to %USERPROFILE%\120fps-backup.

.PARAMETER Revert
    Restores the values recorded in the most recent backup under BackupRoot.

.EXAMPLE
    .\Set-120FpsTweaks.ps1 -WhatIf
.EXAMPLE
    .\Set-120FpsTweaks.ps1 -GameExe "C:\Games\MyGame\MyGame.exe"
.EXAMPLE
    .\Set-120FpsTweaks.ps1 -Revert
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GameExe,
    [string]$BackupRoot = (Join-Path $env:USERPROFILE '120fps-backup'),
    [switch]$Revert
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}

$gpuPrefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'

function Get-Tweaks {
    $tweaks = @(
        @{ Key = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode'; Type = 'DWord'; Value = 2; Label = 'Hardware-accelerated GPU scheduling (reboot required)' },
        @{ Key = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Type = 'DWord'; Value = 1; Label = 'Game Mode' },
        @{ Key = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AllowAutoGameMode'; Type = 'DWord'; Value = 1; Label = 'Game Mode (allow)' },
        @{ Key = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Type = 'DWord'; Value = 0; Label = 'Disable background Game DVR' },
        @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Type = 'DWord'; Value = 0; Label = 'Disable app capture' }
    )

    # Merge SwapEffectUpgradeEnable=1 into the existing global DirectX string rather than overwriting it.
    $current = Get-RegValue -Key $gpuPrefKey -Name 'DirectXUserGlobalSettings'
    $entries = [ordered]@{}
    if ($current) {
        foreach ($pair in ($current -split ';' | Where-Object { $_ -match '=' })) {
            $k, $v = $pair -split '=', 2
            $entries[$k] = $v
        }
    }
    $entries['SwapEffectUpgradeEnable'] = '1'
    $merged = (($entries.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';') + ';'
    $tweaks += @{ Key = $gpuPrefKey; Name = 'DirectXUserGlobalSettings'; Type = 'String'; Value = $merged; Label = 'Optimizations for windowed games' }

    if ($GameExe) {
        if (-not (Test-Path -LiteralPath $GameExe -PathType Leaf)) { throw "GameExe not found: $GameExe" }
        $exe = (Resolve-Path -LiteralPath $GameExe).Path
        $tweaks += @{ Key = $gpuPrefKey; Name = $exe; Type = 'String'; Value = 'GpuPreference=2;'; Label = "High-performance GPU for $exe" }
    }
    return $tweaks
}

function Get-RegValue([string]$Key, [string]$Name) {
    if (-not (Test-Path $Key)) { return $null }
    $item = Get-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Name
}

function Get-ActivePowerScheme {
    $line = powercfg /getactivescheme
    if ($line -match '([0-9a-fA-F-]{36})') { return $Matches[1] }
    return $null
}

function Invoke-Revert {
    $latest = Get-ChildItem -Path $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { throw "No backups found in $BackupRoot" }
    $statePath = Join-Path $latest.FullName 'state.json'
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    Write-Host "Reverting using backup $($latest.FullName)"

    foreach ($entry in $state.Values) {
        if ($entry.Existed) {
            if ($PSCmdlet.ShouldProcess("$($entry.Key)\$($entry.Name)", "Restore '$($entry.Original)'")) {
                New-ItemProperty -Path $entry.Key -Name $entry.Name -PropertyType $entry.Type -Value $entry.Original -Force | Out-Null
            }
        } elseif (Test-Path $entry.Key) {
            if ($PSCmdlet.ShouldProcess("$($entry.Key)\$($entry.Name)", 'Remove (did not exist before)')) {
                Remove-ItemProperty -Path $entry.Key -Name $entry.Name -ErrorAction SilentlyContinue
            }
        }
    }
    if ($state.PowerScheme -and $PSCmdlet.ShouldProcess('Power plan', "Restore $($state.PowerScheme)")) {
        powercfg /setactive $state.PowerScheme
    }
    Write-Host 'Revert complete. Reboot for the GPU scheduling change to take effect.'
}

if ($Revert) { Invoke-Revert; return }

$tweaks = Get-Tweaks
$backupDir = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')

if (-not $WhatIfPreference) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    try {
        Checkpoint-Computer -Description 'Before 120fps tweaks' -RestorePointType MODIFY_SETTINGS
        Write-Host 'System Restore point created.'
    } catch {
        Write-Warning "Could not create a restore point ($($_.Exception.Message)). Continuing with .reg backups only."
    }

    # Export each distinct key that exists, so it can also be restored by double-clicking.
    $i = 0
    foreach ($key in ($tweaks.Key | Select-Object -Unique)) {
        if (Test-Path $key) {
            $regPath = $key -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
            $file = Join-Path $backupDir ("{0:D2}-{1}.reg" -f $i++, ($regPath -split '\\')[-1])
            reg export $regPath $file /y | Out-Null
        }
    }

    $state = @{
        PowerScheme = Get-ActivePowerScheme
        Values      = @($tweaks | ForEach-Object {
            $orig = Get-RegValue -Key $_.Key -Name $_.Name
            @{ Key = $_.Key; Name = $_.Name; Type = $_.Type; Existed = ($null -ne $orig); Original = $orig }
        })
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDir 'state.json') -Encoding UTF8
    Write-Host "Backup written to $backupDir"
}

foreach ($t in $tweaks) {
    if ($PSCmdlet.ShouldProcess("$($t.Key)\$($t.Name)", "Set to '$($t.Value)' [$($t.Label)]")) {
        if (-not (Test-Path $t.Key)) { New-Item -Path $t.Key -Force | Out-Null }
        New-ItemProperty -Path $t.Key -Name $t.Name -PropertyType $t.Type -Value $t.Value -Force | Out-Null
        Write-Host "  [ok] $($t.Label)"
    }
}

# SCHEME_MIN is the built-in High performance plan.
if ($PSCmdlet.ShouldProcess('Power plan', 'Activate High performance (SCHEME_MIN)')) {
    powercfg /setactive SCHEME_MIN
    Write-Host '  [ok] High performance power plan'
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host 'Done. Next steps:'
    Write-Host '  1. Reboot (required for GPU scheduling).'
    Write-Host '  2. Set the display to 120 Hz: Settings > System > Display > Advanced display.'
    Write-Host "  3. To undo: .\Set-120FpsTweaks.ps1 -Revert"
}
