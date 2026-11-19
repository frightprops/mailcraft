<#
.SYNOPSIS
    Retires fixes that upstream no longer needs (status merged or superseded after a sync).

.DESCRIPTION
    For each patch: tags the branch archive/<branch> (pushed to origin, so the code is never lost),
    deletes the branch locally and on origin, closes its upstream pull request if it is still
    open (pointing at what made it unnecessary), and marks it deprecated in patches.toml with the
    release it was found in. Run it after reading the sync report.

.EXAMPLE
    .\Retire-Patch.ps1 -All            # every merged or superseded patch
    .\Retire-Patch.ps1 -Id custom-font-colour
    .\Retire-Patch.ps1 -Id some-fix -Force -Reason 'Upstream redesigned the feature'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $Id,
    [switch] $All,
    [switch] $Force,
    [string] $Reason
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PatchTools.psm1') -Force

$reg = Read-Registry
$paths = Get-Paths $reg
$upstream = $reg.Settings['upstream_repo']

if ($All) {
    $targets = @($reg.Patches | Where-Object { $_['status'] -eq 'merged' -or $_['status'] -eq 'superseded' })
} elseif ($Id) {
    $targets = @($Id | ForEach-Object { Get-Patch $reg $_ })
} else { throw 'Give -Id <id> or -All' }
if ($targets.Count -eq 0) { Write-Host 'Nothing to retire.'; return }

$hasOrigin = (Invoke-Git $paths.Repo @('remote')).Lines -contains 'origin'
if ($hasOrigin) { Invoke-Git $paths.Repo @('fetch', '--prune', 'origin') -AllowFail | Out-Null }

foreach ($p in $targets) {
    $id = $p['id']; $branch = $p['branch']
    if ($p['status'] -eq 'deprecated') { Write-Note "$id is already deprecated"; continue }
    if (-not $Force -and $p['status'] -ne 'merged' -and $p['status'] -ne 'superseded') {
        Write-Warn "$id is '$($p['status'])', not merged or superseded; use -Force to retire it anyway"
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($id, "retire $branch")) { continue }
    Write-Step "Retiring $id"

    $ref = Resolve-PatchRef $paths.Repo $branch
    if ($ref) {
        $archive = "archive/$branch"
        if (-not (Test-RefExists $paths.Repo "refs/tags/$archive")) {
            $why = if ($Reason) { $Reason } else { $p['evidence'] }
            Invoke-Git $paths.Repo @('tag', '-a', $archive, $ref, '-m', "Retired $id ($($p['status']) in $($p['last_checked'])): $why") | Out-Null
        }
        if ($hasOrigin) { Invoke-Git $paths.Repo @('push', 'origin', "refs/tags/$archive") | Out-Null }
        Write-Note "archived as $archive"

        if (Test-RefExists $paths.Repo "refs/heads/$branch") {
            $current = (Invoke-Git $paths.Repo @('branch', '--show-current')).Output.Trim()
            if ($current -eq $branch) { Invoke-Git $paths.Repo @('switch', '--detach', 'refs/remotes/upstream/main') | Out-Null }
            Invoke-Git $paths.Repo @('branch', '-D', $branch) | Out-Null
        }
        if ($hasOrigin -and (Test-RefExists $paths.Repo "refs/remotes/origin/$branch")) {
            Invoke-Git $paths.Repo @('push', 'origin', '--delete', $branch) | Out-Null
        }
        Write-Note 'branch deleted'
    } else {
        Write-Warn "branch $branch not found; nothing to archive"
    }

    if ([int]$p['upstream_pr'] -gt 0) {
        $pr = Invoke-Gh @('pr', 'view', "$($p['upstream_pr'])", '-R', $upstream, '--json', 'state') -AllowFail
        if ($pr.Code -eq 0 -and ($pr.Output | ConvertFrom-Json).state -eq 'OPEN') {
            $why = if ($Reason) { $Reason } else { $p['evidence'] }
            $comment = "Closing: no longer needed on main. $why" -replace '"', "'"
            Invoke-Gh @('pr', 'close', "$($p['upstream_pr'])", '-R', $upstream, '--comment', $comment) | Out-Null
            Write-Note "closed PR #$($p['upstream_pr'])"
        }
    }

    $p['status'] = 'deprecated'
    $p['deprecated_in'] = if ($p['last_checked']) { $p['last_checked'] } else { Get-LatestTag $paths.Repo }
    if ($Reason) { $p['notes'] = ($p['notes'] + ' ' + $Reason).Trim() }
    Write-Registry $reg
}
Write-Host 'Done. The next Sync-Patches.ps1 run leaves the retired fixes out of doug/patched.'
