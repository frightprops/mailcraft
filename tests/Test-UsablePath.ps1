<#
.SYNOPSIS
    A build path on a drive that is not mounted is replaced with C:\cargo\...
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PatchTools.psm1') -Force

$failures = New-Object System.Collections.ArrayList
function Check([bool] $Ok, [string] $What) {
    if ($Ok) { Write-Host "  ok   $What" -ForegroundColor Green }
    else { Write-Host "  FAIL $What" -ForegroundColor Red; [void]$failures.Add($What) }
}

$letters = [IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) }
$missing = @('Q', 'Z', 'Y', 'X', 'W', 'V', 'U') | Where-Object { $letters -notcontains $_ } | Select-Object -First 1
if (-not $missing) { throw 'No unmounted drive letter to test with' }

$joined = $false
try { Join-Path "${missing}:\cargo\sync" 'patched' | Out-Null; $joined = $true } catch { $joined = $false }
Check (-not $joined) "Join-Path refuses ${missing}: (the failure the watch hit)"

$target = Resolve-UsablePath "${missing}:/cargo/sync" 'sync'
$scratch = Resolve-UsablePath "${missing}:/cargo/sync-tmp" 'sync-tmp'
Check ($target -eq 'C:\cargo\sync') "target falls back to C:\cargo\sync (got $target)"
Check ($scratch -eq 'C:\cargo\sync-tmp') "scratch falls back to C:\cargo\sync-tmp (got $scratch)"
# The stand-in is a path Join-Path will accept.
$child = Join-Path $target 'patched'
Check ($child -eq 'C:\cargo\sync\patched') "patched target joins under the stand-in (got $child)"

$reg = Read-Registry
$keptTarget = $reg.Settings['target_dir']
$keptScratch = $reg.Settings['scratch_path']
try {
    $reg.Settings['target_dir'] = "${missing}:/cargo/sync"
    $reg.Settings['scratch_path'] = "${missing}:/cargo/sync-tmp"
    $paths = Get-Paths $reg
    Check ($paths.Target -eq 'C:\cargo\sync') 'Get-Paths uses the stand-in target'
    Check ($paths.Scratch -eq 'C:\cargo\sync-tmp') 'Get-Paths uses the stand-in scratch'
    Check ($paths.PatchedTarget -eq 'C:\cargo\sync\patched') 'Get-Paths joins patched\ on the stand-in'
    Check ($paths.ScratchTarget -eq 'C:\cargo\sync\scratch') 'Get-Paths joins scratch\ on the stand-in'
} finally {
    $reg.Settings['target_dir'] = $keptTarget
    $reg.Settings['scratch_path'] = $keptScratch
}

if ($letters -contains 'C') {
    $here = Resolve-UsablePath 'C:\Windows' 'sync'
    Check ($here -eq 'C:\Windows') 'a path on a mounted drive is kept'
}

if ($failures.Count) { Write-Host "$($failures.Count) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All usable-path checks passed'
