<#
.SYNOPSIS
    Checks a fix branch, pushes it to your fork and opens its upstream pull request (a draft).

.DESCRIPTION
    - The first commit on the branch is taken as the regression-test commit.
    - Unless -NoVerify: the test must FAIL on upstream/main with only the test commit applied,
      and PASS at the branch head. Without that, Sync-Patches.ps1 can't tell later whether
      upstream fixed the bug another way.
    - Pushes the branch to origin and opens a draft pull request against upstream main with
      "Closes #<issue>" (skip with -NoPr; re-run later to open it).
    You sign the CLA yourself, by commenting on your first pull request:
      I have read the MailCraft CLA and I agree to it.

.EXAMPLE
    .\Submit-Patch.ps1 -Id custom-font-colour -TestCmd 'cargo test -p mailcraft-html font_colour'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Id,
    [string] $TestCmd,
    [switch] $NoVerify,
    [switch] $NoPr,
    [switch] $Ready,
    [switch] $AiAssisted
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PatchTools.psm1') -Force

$reg = Read-Registry
$paths = Get-Paths $reg
$patch = Get-Patch $reg $Id
if ($TestCmd) { $patch['test_cmd'] = $TestCmd }
if (-not $patch['test_cmd']) { throw 'Give -TestCmd: the command that runs the regression test.' }
if ($patch['test_cmd'].Contains('"')) { throw 'test_cmd must not contain double quotes (Windows PowerShell 5.1 mangles them).' }
$branch = $patch['branch']
$upstream = $reg.Settings['upstream_repo']

Write-Step 'Fetching upstream'
Update-Remotes $paths.Repo
$ref = Resolve-PatchRef $paths.Repo $branch
if (-not $ref) { throw "Branch $branch not found" }
$commits = Get-PatchCommits $paths.Repo $ref
if ($commits.Count -lt 2) { throw "$branch has $($commits.Count) commit(s) of its own; it needs the test commit first, then the fix." }
$testCommit = $commits[0]
$patch['test_commit'] = $testCommit
$subjects = (Invoke-Git $paths.Repo @('log', '--format=%h %s', '--reverse', '--no-merges', "$($commits[0])~1..$ref")).Lines
Write-Note "Commits on ${branch}:"
$subjects | ForEach-Object { Write-Note "  $_" }
Write-Note "Test commit: $($testCommit.Substring(0, 10))"

$touched = (Invoke-Git $paths.Repo @('diff', '--name-only', "$($commits[0])~1", $ref)).Lines
if (-not ($touched -contains "packaging/release-notes.d/fixes/$($patch['upstream_issue']).md")) {
    Write-Warn "No packaging/release-notes.d/fixes/$($patch['upstream_issue']).md on the branch (upstream wants one for a user-visible fix)."
}
$testOnly = (Invoke-Git $paths.Repo @('diff', '--name-only', "$testCommit~1", $testCommit)).Lines
$nonTest = $testOnly | Where-Object { $_ -notmatch '(^|/)tests?(/|\.rs$)|_tests\.rs$|/lib\.rs$|/mod\.rs$|/main\.rs$' }
if ($nonTest) { Write-Warn "The test commit also touches: $($nonTest -join ', '). Keep it to the test (plus its 'mod x_tests;' line)." }

if (-not $NoVerify) {
    $mergeBase = (Invoke-Git $paths.Repo @('merge-base', $ref, 'refs/remotes/upstream/main')).Output.Trim()

    Write-Step "Test without the fix (must fail): $($patch['test_cmd'])"
    $wt = New-ScratchWorktree $paths.Repo $paths.Scratch "submit-$Id" $mergeBase
    try {
        if (-not (Add-CommitsNoCommit $wt @($testCommit))) { throw 'The test commit does not apply to upstream/main on its own.' }
        $verdict = Get-TestVerdict (Invoke-CommandLine $patch['test_cmd'] $wt (Get-CargoEnv $paths $wt))
    } finally { Remove-ScratchWorktree $paths.Repo $wt }
    Write-Note "Result: $verdict"
    if ($verdict -ne 'fail') { throw "Without the fix the test must fail, but it gave '$verdict'. Fix the test or -TestCmd." }

    Write-Step 'Test with the fix (must pass)'
    $wt = New-ScratchWorktree $paths.Repo $paths.Scratch "submit-$Id" $ref
    try {
        $verdict = Get-TestVerdict (Invoke-CommandLine $patch['test_cmd'] $wt (Get-CargoEnv $paths $wt))
    } finally { Remove-ScratchWorktree $paths.Repo $wt }
    Write-Note "Result: $verdict"
    if ($verdict -ne 'pass') { throw "With the fix the test must pass, but it gave '$verdict'." }
}

Write-Registry $reg

if ($ref -eq "refs/heads/$branch") {
    Write-Step "Pushing $branch to origin"
    Invoke-Git $paths.Repo @('push', '--set-upstream', 'origin', "refs/heads/${branch}:refs/heads/$branch") | Out-Null
}

if ($NoPr) { Write-Host 'Skipped the pull request (-NoPr).'; return }
if ([int]$patch['upstream_pr'] -gt 0) { Write-Host "Pull request #$($patch['upstream_pr']) already recorded."; return }

$owner = Get-ForkOwner $reg
$fixSubject = (Invoke-Git $paths.Repo @('log', '-1', '--format=%s', $ref)).Output.Trim() -replace '"', "'"
$fixBody = (Invoke-Git $paths.Repo @('log', '-1', '--format=%b', $ref)).Output.Trim()
$body = @"
Closes #$($patch['upstream_issue'])

## What changes for the person using MailCraft

$fixBody

## How it was checked

The first commit adds a regression test on its own; it fails on main without the fix and passes with it:
``$($patch['test_cmd'])``

- [x] ``cargo xtask ci`` passes
- [x] A crash or data-loss fix has its regression test
- [x] "Allow edits by maintainers" is ticked (the box beside Create pull request)
- [ ] I have signed the [CLA](../CLA.md), or will by commenting on this pull request
"@
if ($AiAssisted) { $body += "`n`nHuman-reviewed, AI-assisted, nobody's mailbox harmed." }
$bodyFile = Join-Path ([IO.Path]::GetTempPath()) "mailcraft-pr-$Id.md"
[IO.File]::WriteAllText($bodyFile, $body, (New-Object System.Text.UTF8Encoding($false)))

Write-Step "Opening the pull request on $upstream"
$prArgs = @('pr', 'create', '-R', $upstream, '--base', 'main', '--head', "${owner}:$branch", '--title', $fixSubject, '--body-file', $bodyFile)
if (-not $Ready) { $prArgs += '--draft' }
$pr = Invoke-Gh $prArgs
Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
$url = ($pr.Lines | Where-Object { $_ -match '/pull/\d+' } | Select-Object -Last 1)
if ($url -match '/pull/(\d+)') { $patch['upstream_pr'] = [int]$Matches[1] }
Write-Registry $reg
Write-Host "Pull request: $url"
Write-Host 'Review it on GitHub, mark it ready, and (first time only) comment:'
Write-Host '  I have read the MailCraft CLA and I agree to it.'
