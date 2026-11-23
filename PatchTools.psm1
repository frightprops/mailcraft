# Shared helpers for the MailCraft patch-stack scripts.
# Works in Windows PowerShell 5.1 and PowerShell 7 (Windows and Linux).

Set-StrictMode -Version 2

$script:ToolsDir = $PSScriptRoot
$script:RegistryPath = Join-Path $PSScriptRoot 'patches.toml'
$script:PatchKeyOrder = @(
    'id', 'branch', 'upstream_issue', 'upstream_pr', 'base_tag', 'base_commit',
    'test_commit', 'test_cmd', 'status', 'deprecated_in', 'last_checked', 'check_key', 'check_verdict',
    'evidence', 'notes'
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
    target_dir      = '../mailcraft-target-sync'
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
#   scratch_path    temporary worktrees used while checking patches. A path on a drive that
#                   is not mounted is replaced with C:\cargo\sync-tmp
#   target_dir      the scripts' own Cargo build folder (patched\ for doug/patched, scratch\ for
#                   the checks); nothing else may build in it. A path on a drive that is not
#                   mounted is replaced with C:\cargo\sync
#   builds_path     where finished binaries are copied, one folder per build tag
#   build_base      "tag" = latest upstream release tag, "main" = upstream/main
#   build_suffix    build tags are patched/<tag>-<build_suffix>.<n>
#   run_ci_on_build run `cargo nextest run` (or `cargo test`) `--locked --workspace` (with -FullCi,
#                   `cargo xtask ci`) before the release build
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
#   check_key       build base, test commit and test_cmd of the last regression-test check
#   check_verdict   what that check gave; a sync with the same check_key reuses it (-Recheck doesn't)
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

# Writes `$Keys` of each of `$Patches` into patches.toml as it is on disk now, so a patch that
# another script registered or changed while this one ran is kept.
function Save-PatchFields {
    param([object[]] $Patches, [string[]] $Keys)
    $disk = Read-Registry
    foreach ($p in $Patches) {
        $d = $disk.Patches | Where-Object { $_['id'] -eq $p['id'] } | Select-Object -First 1
        if ($null -eq $d) { continue }
        foreach ($k in $Keys) { if ($p.Contains($k)) { $d[$k] = $p[$k] } }
    }
    Write-Registry $disk
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

# Join-Path refuses a path whose drive letter is not mounted ("Cannot find drive"). The build
# folders live on the E: Dev Drive; a machine without it (the upstream-watch runner) uses the
# stand-ins named in the README, C:\cargo\sync and C:\cargo\sync-tmp.
function Resolve-UsablePath {
    param([string] $Configured, [string] $FallbackLeaf)
    $full = Resolve-ToolPath $Configured
    if (Test-IsWindows) {
        $root = [IO.Path]::GetPathRoot($full)
        if ($root -match '^[A-Za-z]:\\$') {
            $mounted = $false
            foreach ($drive in [IO.DriveInfo]::GetDrives()) {
                if ($drive.Name -eq $root) { $mounted = $true; break }
            }
            if (-not $mounted) {
                $fallback = [IO.Path]::GetFullPath((Join-Path 'C:\cargo' $FallbackLeaf))
                Write-Warn "$full is not available (drive $($root.Substring(0, 2)) is not mounted); using $fallback"
                return $fallback
            }
        }
    }
    return $full
}

function Get-Paths {
    param([pscustomobject] $Registry)
    $s = $Registry.Settings
    $target = Resolve-UsablePath $s['target_dir'] 'sync'
    # Cargo names a workspace crate's output by its path within the workspace, so two checkouts
    # building in one folder overwrite each other's crates, and one can link the other's. Only
    # mailcraft-patched builds in patched\; the scratch checkouts, one at a time, in scratch\.
    [pscustomobject]@{
        Repo          = Resolve-ToolPath $s['repo_path']
        Patched       = Resolve-ToolPath $s['patched_path']
        Scratch       = Resolve-UsablePath $s['scratch_path'] 'sync-tmp'
        Target        = $target
        PatchedTarget = Join-Path $target 'patched'
        ScratchTarget = Join-Path $target 'scratch'
        Builds        = Resolve-ToolPath $s['builds_path']
        Reports       = Join-Path $script:ToolsDir 'reports'
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

# One element would unwrap to a string on the way out; the comma keeps the array.
function Get-WorktreePaths {
    param([string] $Repo)
    $paths = New-Object System.Collections.ArrayList
    foreach ($line in @((Invoke-Git $Repo @('worktree', 'list', '--porcelain')).Lines)) {
        if ($line.StartsWith('worktree ')) { [void]$paths.Add($line.Substring(9)) }
    }
    return ,$paths.ToArray()
}

function Test-SamePath {
    param([string] $Left, [string] $Right)
    $a = [IO.Path]::GetFullPath($Left).TrimEnd('\', '/')
    $b = [IO.Path]::GetFullPath($Right).TrimEnd('\', '/')
    if (Test-IsWindows) { return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase) }
    return ($a -ceq $b)
}

function Test-PathUnder {
    param([string] $Root, [string] $Child)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (Test-IsWindows) { return $childFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }
    return $childFull.StartsWith($prefix)
}

function Test-RegisteredWorktree {
    param([string] $Repo, [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    foreach ($w in (Get-WorktreePaths $Repo)) {
        if (Test-SamePath $w $Path) { return $true }
    }
    return $false
}

# One checkout named check, whatever $Name is: Cargo fingerprints store absolute source paths,
# so a new folder would rebuild every crate. Git rewrites only files that differ.
function New-ScratchWorktree {
    param([string] $Repo, [string] $ScratchRoot, [string] $Name, [string] $Ref)
    if (-not (Test-Path -LiteralPath $ScratchRoot)) { New-Item -ItemType Directory -Path $ScratchRoot | Out-Null }
    $path = Join-Path $ScratchRoot 'check'
    # Per-patch folders from before this one checkout.
    foreach ($other in (Get-WorktreePaths $Repo)) {
        if ((Test-PathUnder $ScratchRoot $other) -and -not (Test-SamePath $other $path)) {
            Invoke-Git $Repo @('worktree', 'remove', '--force', $other) -AllowFail | Out-Null
        }
    }
    Invoke-Git $Repo @('worktree', 'prune') -AllowFail | Out-Null
    if (Test-RegisteredWorktree $Repo $path) {
        Invoke-Git $path @('cherry-pick', '--abort') -AllowFail | Out-Null
        Invoke-Git $path @('reset', '--hard', '--quiet') | Out-Null
        Invoke-Git $path @('checkout', '--force', '--quiet', '--detach', $Ref) | Out-Null
        Invoke-Git $path @('clean', '-ffdxq') | Out-Null
    } else {
        Remove-ScratchWorktree -Repo $Repo -Path $path
        Invoke-Git $Repo @('worktree', 'add', '--detach', '--force', $path, $Ref) | Out-Null
    }
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

# Abort a cherry-pick and drop untracked files, but keep the checkout for the next check.
function Reset-ScratchWorktree {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    Invoke-Git $Path @('cherry-pick', '--abort') -AllowFail | Out-Null
    Invoke-Git $Path @('reset', '--hard', '--quiet') -AllowFail | Out-Null
    Invoke-Git $Path @('clean', '-ffdxq') -AllowFail | Out-Null
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
    if (-not $Worktree) { $Worktree = $Paths.Repo }
    $own = [IO.Path]::GetFullPath($Worktree).TrimEnd('\', '/') -eq $Paths.Patched.TrimEnd('\', '/')
    $target = if ($own) { $Paths.PatchedTarget } else { $Paths.ScratchTarget }
    # MAILCRAFT_REPORT_URL empty: a local build never sends Help > Report a Problem to the real relay.
    $envVars = @{ CARGO_TARGET_DIR = $target; MAILCRAFT_REPORT_URL = '' }
    $toolchain = Get-PinnedToolchain $Worktree
    if ($toolchain) { $envVars['RUSTUP_TOOLCHAIN'] = $toolchain }
    return $envVars
}

# ---------------------------------------------------------------- one script at a time

# Sync-Patches.ps1 and Submit-Patch.ps1 share mailcraft-patched, the scratch worktrees and the build
# folders, so only one runs at a time. Returns the open lock file; dispose of it when done. The
# system lets go of it if the script dies.
function Enter-PatchLock {
    param([string] $Script)
    $path = Join-Path $script:ToolsDir '.patch-tools.lock'
    try {
        $lock = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    } catch {
        $holder = 'unknown'
        try {
            $reader = New-Object IO.StreamReader([IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite))
            try { $holder = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        } catch { }
        throw "Another patch script is running ($holder). Wait for it to finish, then run this again."
    }
    $lock.SetLength(0)
    $bytes = [Text.Encoding]::UTF8.GetBytes("$Script, process $PID, since $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    $lock.Write($bytes, 0, $bytes.Length)
    $lock.Flush()
    return $lock
}

function Write-Step { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note { param([string] $Text) Write-Host "    $Text" }
function Write-Warn { param([string] $Text) Write-Host "    ! $Text" -ForegroundColor Yellow }

Export-ModuleMember -Function *
