<#
.SYNOPSIS
    Self-test of the patch-stack scripts on a toy "upstream" and fork, with no network.

.DESCRIPTION
    Four fixes are made on the fork, then "upstream" moves on and makes a release:
      add      - upstream takes the very same commits             -> merged
      double   - upstream fixes the bug its own way               -> superseded
      negate   - upstream leaves the bug alone                    -> active, built in
      greeting - upstream rewrites the same line, bug still there -> conflict, left out
    Then Retire-Patch.ps1 -All and a second sync. Needs git and cargo; takes a minute or two.
#>
[CmdletBinding()]
param([switch] $Keep)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PatchTools.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('patchstack-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null
$failures = New-Object System.Collections.ArrayList
function Check([bool] $Ok, [string] $What) {
    if ($Ok) { Write-Host "  ok   $What" -ForegroundColor Green }
    else { Write-Host "  FAIL $What" -ForegroundColor Red; [void]$failures.Add($What) }
}
function G([string] $Repo) { Invoke-Git $Repo $args | Out-Null }
function Write-File([string] $Path, [string] $Text) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
}
function Commit([string] $Repo, [string] $Message) {
    G $Repo add -A
    G $Repo -c user.name=Test -c user.email=test@example.org commit -q -m $Message
}

try {
    # ------------------------------------------------------------ toy upstream
    $up = Join-Path $root 'upstream-work'
    G $root init -q -b main $up
    Write-File "$up/Cargo.toml" "[workspace]`nmembers = [`"app`", `"cli`"]`nresolver = `"2`"`n"
    Write-File "$up/app/Cargo.toml" "[package]`nname = `"mailcraft`"`nversion = `"0.1.0`"`nedition = `"2021`"`n"
    Write-File "$up/app/src/lib.rs" "pub mod a;`npub mod b;`npub mod c;`npub mod d;`n"
    Write-File "$up/app/src/main.rs" "fn main() { println!(`"{}`", mailcraft::a::add(1, 2)); }`n"
    Write-File "$up/app/src/a.rs" "pub fn add(a: i32, b: i32) -> i32 {`n    a - b`n}`n"
    Write-File "$up/app/src/b.rs" "pub fn double(x: i32) -> i32 {`n    x + 1`n}`n"
    Write-File "$up/app/src/c.rs" "pub fn negate(x: i32) -> i32 {`n    x`n}`n"
    Write-File "$up/app/src/d.rs" "pub fn greeting() -> &'static str {`n    `"helo`"`n}`n"
    Write-File "$up/cli/Cargo.toml" "[package]`nname = `"mailcraft-cli`"`nversion = `"0.1.0`"`nedition = `"2021`"`n"
    Write-File "$up/cli/src/main.rs" "fn main() {}`n"
    Write-File "$up/.gitignore" "target/`n"
    Commit $up 'initial'
    G $up tag v1.0.0
    $bare = Join-Path $root 'upstream.git'
    G $root clone -q --bare $up $bare
    $forkBare = Join-Path $root 'fork.git'
    G $root clone -q --bare $up $forkBare

    # ------------------------------------------------------------ fork clone and tools
    $repo = Join-Path $root 'mailcraft'
    G $root clone -q -o origin $forkBare $repo
    G $repo remote add upstream $bare
    G $repo fetch -q upstream
    $tools = Join-Path $root 'mailcraft-patches'
    New-Item -ItemType Directory -Path $tools | Out-Null
    Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) '*.ps1') $tools
    Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'PatchTools.psm1') $tools

    $fixes = @(
        @{ id = 'add';      issue = 1; file = 'a.rs'; test = 'assert_eq!(mailcraft::a::add(2, 3), 5);';    from = 'a - b';    to = 'a + b' },
        @{ id = 'double';   issue = 2; file = 'b.rs'; test = 'assert_eq!(mailcraft::b::double(4), 8);';    from = 'x + 1';    to = 'x * 2' },
        @{ id = 'negate';   issue = 3; file = 'c.rs'; test = 'assert_eq!(mailcraft::c::negate(5), -5);';   from = '    x';    to = '    -x' },
        @{ id = 'greeting'; issue = 4; file = 'd.rs'; test = 'assert_eq!(mailcraft::d::greeting(), "hello");'; from = '"helo"'; to = '"hello"' }
    )
    $entries = @()
    foreach ($f in $fixes) {
        $branch = "fix/$($f.issue)-$($f.id)"
        G $repo switch -q --no-track -c $branch refs/remotes/upstream/main
        Write-File "$repo/app/tests/$($f.id)_tests.rs" "#[test]`nfn $($f.id)_regression() {`n    $($f.test)`n}`n"
        Commit $repo "Test: $($f.id) regression"
        $src = "$repo/app/src/$($f.file)"
        Write-File $src ([IO.File]::ReadAllText($src).Replace($f.from, $f.to))
        Commit $repo "Fix $($f.id)"
        G $repo push -q origin $branch
        $entries += "[[patch]]`nid = `"$($f.id)`"`nbranch = `"$branch`"`nupstream_issue = 0`nupstream_pr = 0`ntest_cmd = `"cargo test -p mailcraft --test $($f.id)_tests`"`nstatus = `"active`"`n"
    }
    G $repo switch -q --detach refs/remotes/upstream/main
    Write-File "$tools/patches.toml" ("[settings]`nupstream_repo = `"example/toy`"`nfork_repo = `"me/toy`"`nrun_ci_on_build = false`n`n" + ($entries -join "`n"))

    # ------------------------------------------------------------ upstream moves on
    $addBranch = "fix/1-add"
    G $repo branch -q upstream-next refs/remotes/upstream/main
    G $repo switch -q upstream-next
    G $repo -c user.name=Upstream -c user.email=up@example.org cherry-pick "$addBranch~1" $addBranch
    Write-File "$repo/app/src/b.rs" "pub fn double(x: i32) -> i32 {`n    2 * x`n}`n"
    Commit $repo 'double: fixed upstream another way'
    Write-File "$repo/app/src/d.rs" "pub fn greeting() -> &'static str {`n    `"hi there`"`n}`n"
    Commit $repo 'greeting: reworded'
    Write-File "$repo/README.md" "toy`n"
    Commit $repo 'unrelated'
    G $repo tag v1.1.0
    G $repo push -q $bare upstream-next:main v1.1.0
    G $repo switch -q --detach upstream-next
    G $repo branch -q -D upstream-next
    G $repo tag -d v1.1.0

    # ------------------------------------------------------------ first sync
    Write-Host "`n--- Sync-Patches.ps1 (first)" -ForegroundColor Cyan
    & (Join-Path $tools 'Sync-Patches.ps1')
    Check ($LASTEXITCODE -eq 2) 'sync exits 2 when something needs attention'
    function Read-ToyRegistry { $m = Import-Module (Join-Path $tools 'PatchTools.psm1') -Force -PassThru; & $m { Read-Registry } }
    $r = Read-ToyRegistry
    $st = @{}; foreach ($p in $r.Patches) { $st[$p['id']] = $p['status'] }
    Check ($st['add'] -eq 'merged') "add is merged (got $($st['add']))"
    Check ($st['double'] -eq 'superseded') "double is superseded (got $($st['double']))"
    Check ($st['negate'] -eq 'active') "negate is active (got $($st['negate']))"
    Check ($st['greeting'] -eq 'conflict') "greeting is conflict (got $($st['greeting']))"
    $patched = Join-Path $root 'mailcraft-patched'
    Check ([IO.File]::ReadAllText("$patched/app/src/c.rs") -match '-x') 'doug/patched has the negate fix'
    Check ([IO.File]::ReadAllText("$patched/app/src/d.rs") -match 'hi there') 'doug/patched has upstream greeting, not the conflicting fix'
    Check ((Invoke-Git $repo @('tag', '--list', 'patched/v1.1.0-doug.1')).Output.Trim() -eq 'patched/v1.1.0-doug.1') 'build tag patched/v1.1.0-doug.1 made'
    $exe = if (Test-IsWindows) { 'mailcraft.exe' } else { 'mailcraft' }
    Check (Test-Path (Join-Path $root "mailcraft-builds/patched/v1.1.0-doug.1/$exe")) 'binary copied to mailcraft-builds'
    Check (Test-Path (Join-Path $tools 'reports/v1.1.0.md')) 'report written'

    # ------------------------------------------------------------ retire
    Write-Host "`n--- Retire-Patch.ps1 -All" -ForegroundColor Cyan
    & (Join-Path $tools 'Retire-Patch.ps1') -All
    $r = Read-ToyRegistry
    $st = @{}; $dep = @{}; foreach ($p in $r.Patches) { $st[$p['id']] = $p['status']; $dep[$p['id']] = $p['deprecated_in'] }
    Check ($st['add'] -eq 'deprecated' -and $dep['add'] -eq 'v1.1.0') 'add deprecated in v1.1.0'
    Check ($st['double'] -eq 'deprecated') 'double deprecated'
    Check ($st['negate'] -eq 'active') 'negate untouched'
    Check (-not (Test-RefExists $repo 'refs/heads/fix/1-add')) 'add branch deleted'
    Check (Test-RefExists $forkBare 'refs/tags/archive/fix/1-add') 'add archived on origin'
    Check (-not (Test-RefExists $forkBare 'refs/heads/fix/2-double')) 'double branch deleted on origin'

    # ------------------------------------------------------------ second sync
    Write-Host "`n--- Sync-Patches.ps1 (second)" -ForegroundColor Cyan
    & (Join-Path $tools 'Sync-Patches.ps1')
    $report = [IO.File]::ReadAllText((Join-Path $tools 'reports/v1.1.0.md'))
    Check ($report -notmatch '\| add \|') 'retired patches are no longer checked'
    Check ((Invoke-Git $repo @('tag', '--list', 'patched/v1.1.0-doug.2')).Output.Trim() -eq 'patched/v1.1.0-doug.2') 'second build tag patched/v1.1.0-doug.2'
} finally {
    if ($Keep) { Write-Host "`nKept: $root" }
    else {
        Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($failures.Count) { Write-Host "$($failures.Count) check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
