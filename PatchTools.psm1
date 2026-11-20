# Shared helpers for the MailCraft patch-stack scripts.
# Works in Windows PowerShell 5.1 and PowerShell 7 (Windows and Linux).

Set-StrictMode -Version 2

$script:ToolsDir = $PSScriptRoot
$script:RegistryPath = Join-Path $PSScriptRoot 'patches.toml'
$script:PatchKeyOrder = @(
    'id', 'branch', 'upstream_issue', 'upstream_pr', 'base_tag', 'base_commit',
    'test_commit', 'test_cmd', 'status', 'deprecated_in', 'last_checked', 'evidence', 'notes'
)
$script:SettingsKeyOrder = @(
    'upstream_repo', 'fork_repo', 'repo_path', 'patched_path', 'scratch_path', 'target_dir',
    'builds_path', 'build_base', 'build_suffix', 'run_ci_on_build'
)
$script:SettingDefaults = [ordered]@{
    upstream_repo   = 'UCS-Care-Group/mailcraft'
    fork_repo       = ''
    repo_path       = '../mailcraft'
    patched_path    = '../mailcraft-patched'
    scratch_path    = '../mailcraft-sync-tmp'
    target_dir      = '../mailcraft-target'
    builds_path     = '../mailcraft-builds'
    build_base      = 'tag'
    build_suffix    = 'doug'
    run_ci_on_build = $true
}

$script:RegistryHeader = @'
# MailCraft patch registry: one [[patch]] table per local bug fix.
# Read and written by New-Patch.ps1, Submit-Patch.ps1, Sync-Patches.ps1 and Retire-Patch.ps1.
# Values are strings in double quotes, whole numbers, or true/false. Comments are not kept on rewrite.
#
# [settings]
#   upstream_repo   owner/name of the upstream GitHub repository
#   fork_repo       owner/name of your fork (the "origin" remote)
#   repo_path       working clone where fix branches are made (relative to this folder)
#   patched_path    worktree holding doug/patched, the branch that gets built
#   scratch_path    temporary worktrees used while checking patches
#   target_dir      shared CARGO_TARGET_DIR, so dependencies are compiled once
#   builds_path     where finished binaries are copied, one folder per build tag
#   build_base      "tag" = latest upstream release tag, "main" = upstream/main
#   build_suffix    build tags are patched/<tag>-<build_suffix>.<n>
#   run_ci_on_build run `cargo xtask ci` before the release build
#
# [[patch]]
#   id              short name for the fix
#   branch          fix/<issue>-<slug>, based on upstream/main
#   upstream_issue  upstream issue number (required)
#   upstream_pr     upstream pull request number (0 until submitted)
#   base_tag        latest upstream release when the fix was started
#   base_commit     upstream/main commit the branch started from
#   test_commit     the commit that adds only the regression test (first commit on the branch)
#   test_cmd        command that runs the regression test, e.g. cargo test -p mailcraft-html font_colour
#   status          active | merged | superseded | conflict | deprecated
#   deprecated_in   upstream release (or main commit) in which the fix stopped being needed
#   last_checked    what the last sync compared against
#   evidence        why the last sync decided what it did
#   notes           anything else
'@

# ---------------------------------------------------------------- native commands

function Invoke-Native {
    param(
        [Parameter(Mandatory)] [string] $Exe,
        [string[]] $Arguments = @(),
        [string] $WorkDir,
        [switch] $AllowFail,
        [switch] $Quiet,
        # Leave stderr out of Output and Lines (still shown when the command fails).
        [switch] $StdoutOnly
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pushed = $false
    try {
        if ($WorkDir) { Push-Location -LiteralPath $WorkDir; $pushed = $true }
        $records = @(& $Exe @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        if ($pushed) { Pop-Location }
        $ErrorActionPreference = $old
    }
    $all = @($records | ForEach-Object { "$_" })
    $lines = if ($StdoutOnly) { @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) } else { $all }
    $text = $lines -join "`n"
    if (-not $AllowFail -and $code -ne 0) {
        throw "$Exe $($Arguments -join ' ') failed (exit $code):`n$($all -join "`n")"
    }
    if (-not $Quiet -and $env:PATCHTOOLS_VERBOSE) { Write-Host $text }
    [pscustomobject]@{ Code = $code; Output = $text; Lines = $lines }
}

function Invoke-Git {
    param([string] $Repo, [string[]] $Arguments, [switch] $AllowFail)
    Invoke-Native -Exe 'git' -Arguments (@('-C', $Repo) + $Arguments) -AllowFail:$AllowFail
}

function Invoke-Gh {
    param([string[]] $Arguments, [switch] $AllowFail)
    # gh writes hints to stderr; callers parse stdout (JSON, the new pull request's URL).
    Invoke-Native -Exe 'gh' -Arguments $Arguments -AllowFail:$AllowFail -StdoutOnly
}

function Test-IsWindows { return ($env:OS -eq 'Windows_NT') }

# Runs a command line through the platform shell, streaming nothing, returning code and output.
# Avoid double quotes inside the command line: Windows PowerShell 5.1 mangles them for native programs.
function Invoke-CommandLine {
    param([string] $CommandLine, [string] $WorkDir, [hashtable] $Env = @{})
    $saved = @{}
    foreach ($k in $Env.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, $Env[$k], 'Process')
    }
    try {
        if (Test-IsWindows) {
            Invoke-Native -Exe 'cmd.exe' -Arguments @('/d', '/c', $CommandLine) -WorkDir $WorkDir -AllowFail
        } else {
            Invoke-Native -Exe '/bin/sh' -Arguments @('-c', $CommandLine) -WorkDir $WorkDir -AllowFail
        }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
}

# Reads `cargo test` output. Pass needs at least one test run and none failed, so a filter that
# matches nothing never counts as "fixed".
function Get-TestVerdict {
    param([pscustomobject] $Result)
    $passed = 0; $failed = 0; $sawSummary = $false
    foreach ($m in [regex]::Matches($Result.Output, 'test result: (?:ok|FAILED)\. (\d+) passed; (\d+) failed')) {
        $sawSummary = $true
        $passed += [int]$m.Groups[1].Value
        $failed += [int]$m.Groups[2].Value
    }
    if ($failed -gt 0) { return 'fail' }
    if ($sawSummary -and $passed -gt 0 -and $Result.Code -eq 0) { return 'pass' }
    if ($Result.Output -match 'error\[E\d+\]|could not compile|error: could not') { return 'build-error' }
    if ($sawSummary -and $passed -eq 0) { return 'no-tests' }
    if ($Result.Code -ne 0) { return 'fail' }
    return 'no-tests'
}

# ---------------------------------------------------------------- registry (a small TOML subset)

function ConvertFrom-TomlValue {
    param([string] $Text, [string] $Context)
    $t = $Text.Trim()
    if ($t.StartsWith('"')) {
        $sb = New-Object System.Text.StringBuilder
        $i = 1
        while ($i -lt $t.Length) {
            $c = $t[$i]
            if ($c -eq '\') {
                $i++
                if ($i -ge $t.Length) { break }
                switch ($t[$i]) {
                    'n' { [void]$sb.Append("`n") }
                    't' { [void]$sb.Append("`t") }
                    '"' { [void]$sb.Append('"') }
                    '\' { [void]$sb.Append('\') }
                    default { [void]$sb.Append('\').Append($t[$i]) }
                }
            } elseif ($c -eq '"') {
                $rest = $t.Substring($i + 1).Trim()
                if ($rest -ne '' -and -not $rest.StartsWith('#')) { throw "patches.toml: unexpected text after string ($Context)" }
                return $sb.ToString()
            } else {
                [void]$sb.Append($c)
            }
            $i++
        }
        throw "patches.toml: unterminated string ($Context)"
    }
    $hash = $t.IndexOf('#')
    if ($hash -ge 0) { $t = $t.Substring(0, $hash).Trim() }
    if ($t -eq 'true') { return $true }
    if ($t -eq 'false') { return $false }
    $n = 0
    if ([int]::TryParse($t, [ref]$n)) { return $n }
    throw "patches.toml: cannot read value '$t' ($Context)"
}

function ConvertTo-TomlValue {
    param($Value)
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long]) { return "$Value" }
    $s = "$Value" -replace '\\', '\\' -replace '"', '\"' -replace "`r?`n", '\n' -replace "`t", '\t'
    return '"' + $s + '"'
}

function Read-Registry {
    $settings = [ordered]@{}
    foreach ($k in $script:SettingDefaults.Keys) { $settings[$k] = $script:SettingDefaults[$k] }
    $patches = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $script:RegistryPath) {
        $current = $null
        $n = 0
        foreach ($raw in [IO.File]::ReadAllLines($script:RegistryPath)) {
            $n++
            $line = $raw.Trim()
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            if ($line -eq '[settings]') { $current = $settings; continue }
            if ($line -eq '[[patch]]') { $current = [ordered]@{}; [void]$patches.Add($current); continue }
            if ($line -match '^([A-Za-z0-9_]+)\s*=\s*(.*)$') {
                if ($null -eq $current) { throw "patches.toml line ${n}: key outside a table" }
                $current[$Matches[1]] = ConvertFrom-TomlValue -Text $Matches[2] -Context "line $n"
                continue
            }
            throw "patches.toml line ${n}: cannot read '$raw'"
        }
    }
    foreach ($p in $patches) {
        foreach ($k in $script:PatchKeyOrder) {
            if (-not $p.Contains($k)) {
                if ($k -eq 'upstream_issue' -or $k -eq 'upstream_pr') { $p[$k] = 0 } else { $p[$k] = '' }
            }
        }
    }
    [pscustomobject]@{ Settings = $settings; Patches = $patches }
}

function Write-Registry {
    param([pscustomobject] $Registry)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($script:RegistryHeader.TrimEnd())
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('[settings]')
    $keys = @($script:SettingsKeyOrder) + @($Registry.Settings.Keys | Where-Object { $script:SettingsKeyOrder -notcontains $_ })
    foreach ($k in $keys) {
        if ($Registry.Settings.Contains($k)) { [void]$sb.AppendLine("$k = $(ConvertTo-TomlValue $Registry.Settings[$k])") }
    }
    foreach ($p in $Registry.Patches) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('[[patch]]')
        $keys = @($script:PatchKeyOrder) + @($p.Keys | Where-Object { $script:PatchKeyOrder -notcontains $_ })
        foreach ($k in $keys) {
            if ($p.Contains($k)) { [void]$sb.AppendLine("$k = $(ConvertTo-TomlValue $p[$k])") }
        }
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($script:RegistryPath, ($sb.ToString() -replace "`r`n", "`n"), $utf8)
}

function Get-Patch {
    param([pscustomobject] $Registry, [string] $Id)
    $p = $Registry.Patches | Where-Object { $_['id'] -eq $Id } | Select-Object -First 1
    if ($null -eq $p) { throw "No patch with id '$Id' in patches.toml" }
    return $p
}

# ---------------------------------------------------------------- paths and refs

function Resolve-ToolPath {
    param([string] $Relative)
    if ([IO.Path]::IsPathRooted($Relative)) { return [IO.Path]::GetFullPath($Relative) }
    return [IO.Path]::GetFullPath((Join-Path $script:ToolsDir $Relative))
}

function Get-Paths {
    param([pscustomobject] $Registry)
    $s = $Registry.Settings
    [pscustomobject]@{
        Repo    = Resolve-ToolPath $s['repo_path']
        Patched = Resolve-ToolPath $s['patched_path']
        Scratch = Resolve-ToolPath $s['scratch_path']
        Target  = Resolve-ToolPath $s['target_dir']
        Builds  = Resolve-ToolPath $s['builds_path']
        Reports = Join-Path $script:ToolsDir 'reports'
    }
}

function Update-Remotes {
    param([string] $Repo)
    Invoke-Git $Repo @('fetch', '--prune', '--tags', '--force', 'upstream') | Out-Null
    $remotes = (Invoke-Git $Repo @('remote')).Lines
    if ($remotes -contains 'origin') { Invoke-Git $Repo @('fetch', '--prune', 'origin') -AllowFail | Out-Null }
}

function Get-LatestTag {
    param([string] $Repo)
    $tags = (Invoke-Git $Repo @('tag', '--list', 'v*')).Lines | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' }
    if (-not $tags) { throw 'No upstream release tags (vX.Y.Z) found' }
    return ($tags | Sort-Object { [version]($_.Substring(1)) } -Descending | Select-Object -First 1)
}

function Test-RefExists {
    param([string] $Repo, [string] $Ref)
    return ((Invoke-Git $Repo @('rev-parse', '--verify', '--quiet', "$Ref^{commit}") -AllowFail).Code -eq 0)
}

function Get-Sha {
    param([string] $Repo, [string] $Ref)
    return (Invoke-Git $Repo @('rev-parse', "$Ref^{commit}")).Output.Trim()
}

function Test-IsAncestor {
    param([string] $Repo, [string] $Ancestor, [string] $Descendant)
    return ((Invoke-Git $Repo @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFail).Code -eq 0)
}

# The newest of the local branch and origin's copy (a maintainer may have pushed to the PR branch).
function Resolve-PatchRef {
    param([string] $Repo, [string] $Branch)
    $local = Test-RefExists $Repo "refs/heads/$Branch"
    $remote = Test-RefExists $Repo "refs/remotes/origin/$Branch"
    if ($local -and $remote) {
        $same = (Get-Sha $Repo "refs/heads/$Branch") -eq (Get-Sha $Repo "refs/remotes/origin/$Branch")
        if (-not $same -and (Test-IsAncestor $Repo "refs/heads/$Branch" "refs/remotes/origin/$Branch")) { return "refs/remotes/origin/$Branch" }
        return "refs/heads/$Branch"
    }
    if ($local) { return "refs/heads/$Branch" }
    if ($remote) { return "refs/remotes/origin/$Branch" }
    return $null
}

# The patch's own commits, oldest first: what the branch adds on top of upstream/main.
function Get-PatchCommits {
    param([string] $Repo, [string] $Ref, [string] $Since)
    $base = (Invoke-Git $Repo @('merge-base', $Ref, 'refs/remotes/upstream/main')).Output.Trim()
    # Once upstream merges the branch, it is all in upstream/main: count from where it started.
    if ($Since -and $base -eq (Get-Sha $Repo $Ref) -and (Test-IsAncestor $Repo $Since $Ref)) { $base = $Since }
    $list = (Invoke-Git $Repo @('rev-list', '--reverse', '--no-merges', "$base..$Ref")).Lines | Where-Object { $_ -match '^[0-9a-f]{40}$' }
    return @($list)
}

function Get-ForkOwner {
    param([pscustomobject] $Registry)
    $fork = $Registry.Settings['fork_repo']
    if (-not $fork) { throw 'settings.fork_repo is empty in patches.toml' }
    return $fork.Split('/')[0]
}

# ---------------------------------------------------------------- scratch worktrees

function New-ScratchWorktree {
    param([string] $Repo, [string] $ScratchRoot, [string] $Name, [string] $Ref)
    if (-not (Test-Path -LiteralPath $ScratchRoot)) { New-Item -ItemType Directory -Path $ScratchRoot | Out-Null }
    $path = Join-Path $ScratchRoot $Name
    Remove-ScratchWorktree -Repo $Repo -Path $path
    Invoke-Git $Repo @('worktree', 'add', '--detach', '--force', $path, $Ref) | Out-Null
    return $path
}

function Remove-ScratchWorktree {
    param([string] $Repo, [string] $Path)
    if (Test-Path -LiteralPath $Path) {
        Invoke-Git $Repo @('worktree', 'remove', '--force', $Path) -AllowFail | Out-Null
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Invoke-Git $Repo @('worktree', 'prune') -AllowFail | Out-Null
}

# Applies commits without committing. Returns $true when they all applied cleanly.
function Add-CommitsNoCommit {
    param([string] $Worktree, [string[]] $Commits)
    $r = Invoke-Git $Worktree (@('cherry-pick', '--no-commit') + $Commits) -AllowFail
    if ($r.Code -ne 0) {
        Invoke-Git $Worktree @('cherry-pick', '--abort') -AllowFail | Out-Null
        Invoke-Git $Worktree @('reset', '--hard', '--quiet') -AllowFail | Out-Null
        return $false
    }
    return $true
}

# The Rust version upstream's CI pins at this checkout (a newer stable brings clippy lints that
# upstream doesn't run yet, so `cargo xtask ci` would fail on code upstream considers clean).
function Get-PinnedToolchain {
    param([string] $Worktree)
    $ci = Join-Path $Worktree '.github/workflows/ci.yml'
    if (-not (Test-Path -LiteralPath $ci)) { return $null }
    $m = Select-String -LiteralPath $ci -Pattern '^\s*toolchain:\s*([0-9][0-9.]*)\s*$' | Select-Object -First 1
    if ($null -eq $m) { return $null }
    $version = $m.Matches[0].Groups[1].Value
    $installed = (Invoke-Native -Exe 'rustup' -Arguments @('toolchain', 'list') -AllowFail).Output
    if ($installed -notmatch "(?m)^$([regex]::Escape($version))-") {
        Write-Note "Installing Rust $version (pinned by upstream CI)"
        Invoke-Native -Exe 'rustup' -Arguments @('toolchain', 'install', $version, '--profile', 'minimal',
            '--component', 'rustfmt,clippy', '--target', 'wasm32-unknown-unknown') | Out-Null
    }
    return $version
}

function Get-CargoEnv {
    param([pscustomobject] $Paths, [string] $Worktree)
    # MAILCRAFT_REPORT_URL empty: a local build never sends Help > Report a Problem to the real relay.
    $envVars = @{ CARGO_TARGET_DIR = $Paths.Target; MAILCRAFT_REPORT_URL = '' }
    if (-not $Worktree) { $Worktree = $Paths.Repo }
    $toolchain = Get-PinnedToolchain $Worktree
    if ($toolchain) { $envVars['RUSTUP_TOOLCHAIN'] = $toolchain }
    return $envVars
}

function Write-Step { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note { param([string] $Text) Write-Host "    $Text" }
function Write-Warn { param([string] $Text) Write-Host "    ! $Text" -ForegroundColor Yellow }

Export-ModuleMember -Function *
