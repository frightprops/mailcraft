<#
.SYNOPSIS
    Starts a new fix: a branch fix/<issue>-<slug> from upstream/main, and its entry in patches.toml.

.DESCRIPTION
    File the upstream problem report first (or find the existing one):
    https://github.com/UCS-Care-Group/mailcraft/issues/new?template=problem.yml

    Then build the fix as two commits on the new branch:
      1. the regression test alone, in a file of its own (tests.rs, <name>_tests.rs or tests/),
         which fails on upstream as it is;
      2. the fix, with its release-notes fragment packaging/release-notes.d/fixes/<issue>.md.
    Finish with Submit-Patch.ps1.

.EXAMPLE
    .\New-Patch.ps1 -Issue 1464 -Slug custom-font-colour
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $Issue,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Slug,
    [string] $Id,
    [string] $Notes = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PatchTools.psm1') -Force

$reg = Read-Registry
$paths = Get-Paths $reg
if (-not $Id) { $Id = $Slug }
$branch = "fix/$Issue-$Slug"

if ($reg.Patches | Where-Object { $_['id'] -eq $Id }) { throw "A patch with id '$Id' already exists" }
if ($reg.Patches | Where-Object { $_['branch'] -eq $branch -and $_['status'] -ne 'deprecated' }) { throw "Branch $branch is already registered" }

$dirty = (Invoke-Git $paths.Repo @('status', '--porcelain')).Output
if ($dirty.Trim()) { throw "The working clone $($paths.Repo) has uncommitted changes; commit or stash them first." }

Write-Step "Checking issue #$Issue upstream"
$issueInfo = Invoke-Gh @('issue', 'view', "$Issue", '-R', $reg.Settings['upstream_repo'], '--json', 'number,title,state') -AllowFail
if ($issueInfo.Code -ne 0) { throw "Upstream issue #$Issue was not found. File it first: https://github.com/$($reg.Settings['upstream_repo'])/issues/new?template=problem.yml" }
$issueJson = $issueInfo.Output | ConvertFrom-Json
Write-Note "#$($issueJson.number) [$($issueJson.state)] $($issueJson.title)"

Write-Step 'Fetching upstream'
Update-Remotes $paths.Repo
$tag = Get-LatestTag $paths.Repo
$base = Get-Sha $paths.Repo 'refs/remotes/upstream/main'

Write-Step "Creating $branch from upstream/main ($($base.Substring(0, 10)))"
Invoke-Git $paths.Repo @('switch', '--no-track', '-c', $branch, 'refs/remotes/upstream/main') | Out-Null

$entry = [ordered]@{
    id             = $Id
    branch         = $branch
    upstream_issue = $Issue
    upstream_pr    = 0
    base_tag       = $tag
    base_commit    = $base
    test_commit    = ''
    test_cmd       = ''
    status         = 'active'
    deprecated_in  = ''
    last_checked   = ''
    evidence       = ''
    notes          = $Notes
}
[void]$reg.Patches.Add($entry)
Write-Registry $reg

Write-Host ''
Write-Host "Registered '$Id'. Next, in $($paths.Repo):"
Write-Host '  1. Commit the regression test alone (it must fail without the fix).'
Write-Host "  2. Commit the fix, with packaging/release-notes.d/fixes/$Issue.md."
Write-Host '  3. Run: cargo xtask ci'
Write-Host "  4. Run: .\Submit-Patch.ps1 -Id $Id -TestCmd 'cargo test -p <crate> <test name>'"
