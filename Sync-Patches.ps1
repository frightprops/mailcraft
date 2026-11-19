<#
.SYNOPSIS
    After an upstream release: decides which of your fixes are still needed, writes a report,
    and rebuilds doug/patched (upstream + the fixes still needed).

.DESCRIPTION
    For each patch that is not deprecated, in order:
      1. Merged pull request: upstream merged your PR and the build base contains it -> merged
      2. Identical change: `git cherry` finds every commit of the patch already upstream -> merged
      3. Fixed another way: only the regression test, applied to the build base, now passes -> superseded
      4. Issue state: the upstream issue's state is added as evidence (closed as not planned is flagged)
      5. Otherwise: the fix is applied to the build base on trial -> active, or conflict
    Then (unless -DryRun) patches.toml gets each status, doug/patched is recreated as
    build base + active fixes, built (`cargo xtask ci`, then a release build), tagged
    <tag>-<suffix>.<n>, and the binaries copied to builds_path.
    Retiring merged and superseded fixes is a separate, deliberate step: Retire-Patch.ps1.

.PARAMETER Base
    'tag' (latest upstream release, the default from settings) or 'main' (upstream/main).
.PARAMETER Tag
    Build on this release tag instead of the latest.
.PARAMETER DryRun
    Detect and write the report only; change nothing else.
.PARAMETER NoBuild
    Recreate doug/patched but skip cargo and the build tag.
.PARAMETER SkipTests
    Skip check 3 (running each regression test on the build base).
.PARAMETER Push
    Push doug/patched and the build tag to origin.
#>
[CmdletBinding()]
param(
    [ValidateSet('tag', 'main')] [string] $Base,
    [string] $Tag,
    [switch] $DryRun,
    [switch] $NoBuild,
    [switch] $SkipTests,
    [switch] $Push
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PatchTools.psm1') -Force

$reg = Read-Registry
$paths = Get-Paths $reg
$upstream = $reg.Settings['upstream_repo']
if (-not $Base) { $Base = $reg.Settings['build_base'] }
$haveGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)

Write-Step 'Fetching upstream and origin'
Update-Remotes $paths.Repo

if ($Base -eq 'main') {
    $buildRef = 'refs/remotes/upstream/main'
    $short = (Get-Sha $paths.Repo $buildRef).Substring(0, 10)
    $latest = Get-LatestTag $paths.Repo
    $label = "$latest-main-$short"
} else {
    if (-not $Tag) { $Tag = Get-LatestTag $paths.Repo }
    if (-not (Test-RefExists $paths.Repo "refs/tags/$Tag")) { throw "Tag $Tag not found" }
    $buildRef = "refs/tags/$Tag"
    $label = $Tag
}
$buildSha = Get-Sha $paths.Repo $buildRef
Write-Note "Build base: $label ($($buildSha.Substring(0, 10)))"

$results = New-Object System.Collections.ArrayList

foreach ($p in @($reg.Patches | Where-Object { $_['status'] -ne 'deprecated' })) {
    $id = $p['id']
    Write-Step "Checking $id ($($p['branch']))"
    $evidence = New-Object System.Collections.ArrayList
    $status = $null
    $commits = @()

    $ref = Resolve-PatchRef $paths.Repo $p['branch']
    if (-not $ref) {
        [void]$evidence.Add("branch $($p['branch']) not found locally or on origin")
        $status = 'conflict'
    } else {
        if ($ref -like 'refs/remotes/*') { [void]$evidence.Add("using origin's copy of the branch (newer than local)") }
        $commits = @(Get-PatchCommits $paths.Repo $ref)
    }

    # 1. Merged pull request
    $prMergedPending = $false
    if (-not $status -and [int]$p['upstream_pr'] -gt 0 -and $haveGh) {
        $pr = Invoke-Gh @('pr', 'view', "$($p['upstream_pr'])", '-R', $upstream, '--json', 'state,mergeCommit,mergedAt') -AllowFail
        if ($pr.Code -eq 0) {
            $prJson = $pr.Output | ConvertFrom-Json
            if ($prJson.state -eq 'MERGED' -and $prJson.mergeCommit) {
                $mc = $prJson.mergeCommit.oid
                if ((Test-RefExists $paths.Repo $mc) -and (Test-IsAncestor $paths.Repo $mc $buildRef)) {
                    $status = 'merged'
                    [void]$evidence.Add("PR #$($p['upstream_pr']) merged as $($mc.Substring(0, 10)), included in $label")
                } else {
                    $prMergedPending = $true
                    [void]$evidence.Add("PR #$($p['upstream_pr']) merged as $($mc.Substring(0, 10)) but not yet in $label")
                }
            } else {
                [void]$evidence.Add("PR #$($p['upstream_pr']) is $($prJson.state.ToLower())")
            }
        } else {
            [void]$evidence.Add("PR #$($p['upstream_pr']) could not be read")
        }
    }

    # 2. Identical change already upstream (patch-id comparison)
    if (-not $status -and $commits.Count -gt 0) {
        $cherry = (Invoke-Git $paths.Repo @('cherry', $buildRef, $ref, "$($commits[0])~1")).Lines | Where-Object { $_ -match '^[+-] ' }
        $missing = @($cherry | Where-Object { $_.StartsWith('+') })
        if ($cherry -and $missing.Count -eq 0) {
            $status = 'merged'
            [void]$evidence.Add("every commit of the patch is already in $label (git cherry)")
        }
    }

    # 3. Fixed another way: the regression test alone passes on the build base
    $testVerdict = ''
    if (-not $status -and -not $SkipTests -and $p['test_cmd'] -and $commits.Count -gt 0) {
        $testCommit = $p['test_commit']
        if (-not $testCommit -or ($commits -notcontains $testCommit)) {
            if ($testCommit) { [void]$evidence.Add('recorded test_commit no longer on the branch; using its first commit') }
            $testCommit = $commits[0]
        }
        $wt = New-ScratchWorktree $paths.Repo $paths.Scratch $id $buildRef
        try {
            if (Add-CommitsNoCommit $wt @($testCommit)) {
                Write-Note "Running the test without the fix: $($p['test_cmd'])"
                $testVerdict = Get-TestVerdict (Invoke-CommandLine $p['test_cmd'] $wt (Get-CargoEnv $paths $wt))
                switch ($testVerdict) {
                    'pass' { $status = 'superseded'; [void]$evidence.Add("regression test passes on $label without the fix") }
                    'fail' { [void]$evidence.Add("regression test still fails on $label without the fix") }
                    default { [void]$evidence.Add("regression test inconclusive on ${label}: $testVerdict") }
                }
            } else {
                $testVerdict = 'does-not-apply'
                [void]$evidence.Add("regression test commit does not apply to $label (upstream changed that code; review by hand)")
            }
        } finally { Remove-ScratchWorktree $paths.Repo $wt }
    }

    # 4. Upstream issue state
    $issueNote = ''
    if ([int]$p['upstream_issue'] -gt 0 -and $haveGh) {
        $iss = Invoke-Gh @('issue', 'view', "$($p['upstream_issue'])", '-R', $upstream, '--json', 'state,stateReason,closedByPullRequestsReferences') -AllowFail
        if ($iss.Code -eq 0) {
            $issJson = $iss.Output | ConvertFrom-Json
            $issueNote = "issue #$($p['upstream_issue']) $($issJson.state.ToLower())"
            if ($issJson.stateReason) { $issueNote += " ($($issJson.stateReason.ToLower()))" }
            $closers = @($issJson.closedByPullRequestsReferences | ForEach-Object { "#$($_.number)" })
            if ($closers.Count -gt 0) { $issueNote += " by $($closers -join ', ')" }
            if ($issJson.stateReason -eq 'NOT_PLANNED') { $issueNote += ': upstream declined it, so keep this fix yourself' }
            [void]$evidence.Add($issueNote)
        }
    }

    # 5. Still needed: does it apply to the build base?
    if (-not $status) {
        $wt = New-ScratchWorktree $paths.Repo $paths.Scratch $id $buildRef
        try {
            if (Add-CommitsNoCommit $wt $commits) {
                $status = 'active'
                [void]$evidence.Add("still needed; applies cleanly to $label")
            } else {
                $status = 'conflict'
                [void]$evidence.Add("still needed; conflicts with $label (rebase the branch by hand)")
            }
        } finally { Remove-ScratchWorktree $paths.Repo $wt }
    }
    if ($prMergedPending -and $status -eq 'active') { [void]$evidence.Add('will be retired once a release contains it') }

    Write-Note "=> $status"
    [void]$results.Add([pscustomobject]@{
        Patch = $p; Id = $id; Status = $status; Ref = $ref; Commits = $commits
        Evidence = ($evidence -join '; '); Test = $testVerdict
    })
}

# ---------------------------------------------------------------- rebuild doug/patched

$build = [pscustomobject]@{ Branch = 'doug/patched'; Applied = @(); Failed = @(); Tag = ''; Binaries = ''; Ci = 'not run'; Note = '' }
if (-not $DryRun) {
    foreach ($r in $results) {
        $r.Patch['status'] = $r.Status
        $r.Patch['last_checked'] = $label
        $r.Patch['evidence'] = $r.Evidence
    }

    Write-Step "Recreating doug/patched at $label"
    if (-not (Test-Path -LiteralPath $paths.Patched)) {
        Invoke-Git $paths.Repo @('worktree', 'add', '-B', 'doug/patched', $paths.Patched, $buildRef) | Out-Null
    } else {
        Invoke-Git $paths.Patched @('cherry-pick', '--abort') -AllowFail | Out-Null
        Invoke-Git $paths.Patched @('reset', '--hard', '--quiet') | Out-Null
        Invoke-Git $paths.Patched @('checkout', '--quiet', '-B', 'doug/patched', $buildRef) | Out-Null
    }
    foreach ($r in @($results | Where-Object { $_.Status -eq 'active' })) {
        $pick = Invoke-Git $paths.Patched (@('cherry-pick', '-x') + $r.Commits) -AllowFail
        if ($pick.Code -eq 0) {
            $build.Applied += $r.Id
            Write-Note "applied $($r.Id)"
        } else {
            Invoke-Git $paths.Patched @('cherry-pick', '--abort') -AllowFail | Out-Null
            $build.Failed += $r.Id
            $r.Status = 'conflict'
            $r.Patch['status'] = 'conflict'
            $r.Evidence += '; conflicts with the other fixes in doug/patched'
            $r.Patch['evidence'] = $r.Evidence
            Write-Warn "$($r.Id) conflicts with the fixes before it; left out"
        }
    }
    Write-Registry $reg

    if (-not $NoBuild) {
        $cargoEnv = Get-CargoEnv $paths $paths.Patched
        Write-Note "Rust toolchain: $(if ($cargoEnv.Contains('RUSTUP_TOOLCHAIN')) { $cargoEnv['RUSTUP_TOOLCHAIN'] } else { 'default' })"
        if ($reg.Settings['run_ci_on_build']) {
            Write-Step 'cargo xtask ci (this takes a while)'
            $ci = Invoke-CommandLine 'cargo xtask ci' $paths.Patched $cargoEnv
            $build.Ci = if ($ci.Code -eq 0) { 'passed' } else { 'FAILED' }
            if ($ci.Code -ne 0) {
                $log = Join-Path $paths.Reports "$label-ci.log"
                if (-not (Test-Path $paths.Reports)) { New-Item -ItemType Directory $paths.Reports | Out-Null }
                [IO.File]::WriteAllText($log, $ci.Output)
                $build.Note = "cargo xtask ci failed; see $log. No build tag made."
                Write-Warn $build.Note
            }
        }
        if ($build.Ci -ne 'FAILED') {
            Write-Step 'cargo build --release -p mailcraft -p mailcraft-cli'
            $rb = Invoke-CommandLine 'cargo build --release -p mailcraft -p mailcraft-cli' $paths.Patched $cargoEnv
            if ($rb.Code -ne 0) {
                $build.Note = "Release build failed:`n$($rb.Output | Select-Object -Last 1)"
                Write-Warn 'Release build failed'
            } else {
                $suffix = $reg.Settings['build_suffix']
                $prefix = "$label-$suffix."
                $nums = (Invoke-Git $paths.Repo @('tag', '--list', "$prefix*")).Lines |
                    ForEach-Object { $_.Substring($prefix.Length) } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
                $next = 1 + ($nums | Measure-Object -Maximum).Maximum
                $build.Tag = "$prefix$next"
                $msg = "MailCraft $label with: " + ($(if ($build.Applied) { $build.Applied -join ', ' } else { 'no local fixes' }))
                Invoke-Git $paths.Patched @('tag', '-a', $build.Tag, '-m', $msg) | Out-Null

                $dest = Join-Path $paths.Builds $build.Tag
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                $ext = if (Test-IsWindows) { '.exe' } else { '' }
                foreach ($bin in @("mailcraft$ext", "mailcraft-cli$ext")) {
                    $src = Join-Path (Join-Path $paths.Target 'release') $bin
                    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dest -Force }
                }
                $build.Binaries = $dest
                Write-Note "Tagged $($build.Tag); binaries in $dest"
            }
        }
    }

    if ($Push) {
        Write-Step 'Pushing doug/patched and the build tag to origin'
        Invoke-Git $paths.Repo @('push', '--force-with-lease', 'origin', 'refs/heads/doug/patched:refs/heads/doug/patched') | Out-Null
        if ($build.Tag) { Invoke-Git $paths.Repo @('push', 'origin', "refs/tags/$($build.Tag)") | Out-Null }
        Invoke-Git $paths.Repo @('push', 'origin', 'refs/heads/patch-tools:refs/heads/patch-tools') -AllowFail | Out-Null
    }
}

# ---------------------------------------------------------------- report

if (-not (Test-Path $paths.Reports)) { New-Item -ItemType Directory $paths.Reports | Out-Null }
$reportPath = Join-Path $paths.Reports "$label.md"
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Patch sync against $label")
[void]$md.AppendLine()
[void]$md.AppendLine("- Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$md.AppendLine("- Build base: ``$label`` ($($buildSha.Substring(0, 10)))")
if ($DryRun) { [void]$md.AppendLine('- Dry run: nothing changed') }
[void]$md.AppendLine()
[void]$md.AppendLine('| Patch | Branch | Issue | PR | Result | Evidence |')
[void]$md.AppendLine('|---|---|---|---|---|---|')
foreach ($r in $results) {
    $iss = if ([int]$r.Patch['upstream_issue'] -gt 0) { "[#$($r.Patch['upstream_issue'])](https://github.com/$upstream/issues/$($r.Patch['upstream_issue']))" } else { '' }
    $prc = if ([int]$r.Patch['upstream_pr'] -gt 0) { "[#$($r.Patch['upstream_pr'])](https://github.com/$upstream/pull/$($r.Patch['upstream_pr']))" } else { '' }
    [void]$md.AppendLine("| $($r.Id) | ``$($r.Patch['branch'])`` | $iss | $prc | **$($r.Status)** | $($r.Evidence -replace '\|', '/') |")
}
if ($results.Count -eq 0) { [void]$md.AppendLine('| (no patches registered) | | | | | |') }

$retire = @($results | Where-Object { $_.Status -eq 'merged' -or $_.Status -eq 'superseded' })
$conflicts = @($results | Where-Object { $_.Status -eq 'conflict' })
[void]$md.AppendLine()
[void]$md.AppendLine('## Next steps')
[void]$md.AppendLine()
if ($retire.Count) {
    [void]$md.AppendLine("- Ready to retire (no longer needed): $(($retire | ForEach-Object { $_.Id }) -join ', '). Confirm, then run ``.\Retire-Patch.ps1 -All``.")
}
if ($conflicts.Count) {
    [void]$md.AppendLine("- Needs your attention (left out of the build): $(($conflicts | ForEach-Object { $_.Id }) -join ', '). Rebase the branch onto upstream/main, re-run Submit-Patch.ps1 -NoPr, then sync again.")
}
if (-not $retire.Count -and -not $conflicts.Count) { [void]$md.AppendLine('- Nothing to do.') }

if (-not $DryRun) {
    [void]$md.AppendLine()
    [void]$md.AppendLine('## Build')
    [void]$md.AppendLine()
    [void]$md.AppendLine("- Branch ``doug/patched`` = ``$label`` + $(if ($build.Applied) { $build.Applied -join ', ' } else { 'no local fixes' })")
    if ($build.Failed) { [void]$md.AppendLine("- Left out (conflict): $($build.Failed -join ', ')") }
    if ($NoBuild) { [void]$md.AppendLine('- Build skipped (-NoBuild)') } else {
        [void]$md.AppendLine("- cargo xtask ci: $($build.Ci)")
        if ($build.Tag) { [void]$md.AppendLine("- Tag ``$($build.Tag)``; binaries in ``$($build.Binaries)``") }
        if ($build.Note) { [void]$md.AppendLine("- $($build.Note)") }
    }
}
[IO.File]::WriteAllText($reportPath, ($md.ToString() -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "Report: $reportPath"
$results | Select-Object Id, Status, Evidence | Format-Table -AutoSize -Wrap
if ($retire.Count -or $conflicts.Count) { exit 2 }
