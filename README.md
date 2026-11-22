# MailCraft patch stack

This branch (`patch-tools`, no shared history with MailCraft) keeps Doug's local MailCraft bug
fixes organised so that each one can be dropped as soon as upstream
([UCS-Care-Group/mailcraft](https://github.com/UCS-Care-Group/mailcraft)) has fixed it.

## Layout on disk

| Folder | What it is |
|---|---|
| `mailcraft/` | Working clone. Remotes: `origin` = your fork, `upstream` = UCS-Care-Group. Fix branches are made here. |
| `mailcraft-patches/` | This branch, as a git worktree: registry, scripts, reports. |
| `mailcraft-patched/` | Worktree of `doug/patched`, the branch that is built and run. Recreated on every sync. |
| `E:\cargo\sync\` | The scripts' own Cargo build folders: `patched\` (only `mailcraft-patched` builds there) and `scratch\` (the regression-test checks). Nothing else builds in it; see [Keeping syncs fast](#keeping-syncs-fast). |
| `E:\cargo\sync-tmp\check` | One reused checkout for the checks and for putting `doug/patched` together. |
| `mailcraft-builds/<tag>/` | Finished `mailcraft.exe` and `mailcraft-cli.exe` for each build tag. |
| `mailcraft-builds/current/` | A copy of the latest build (`BUILD.txt` says which); the taskbar pin starts this one. Close MailCraft before a sync so it can be replaced. |

## Branches

- `main`: mirrors `upstream/main`. Never commit to it.
- `fix/<issue>-<slug>`: one per bug, based on `upstream/main` (upstream only accepts pull requests
  based on `main`), and opened as a pull request upstream.
- `doug/patched`: the latest upstream release tag plus the commits of every fix still needed.
  It is recreated from scratch on each sync, never merged forward.
- `patch-tools`: this branch.
- Tags `patched/vX.Y.Z-doug.N`: your builds. Tags `archive/fix/...`: retired fixes, kept for reference.
  Never push a tag shaped like `vX.Y.Z` or `vX.Y.Z-*` to the fork: upstream's `release.yml` and
  `freebsd.yml` run on those.

## The fork on GitHub ([frightprops/mailcraft](https://github.com/frightprops/mailcraft))

- Its default branch is `patch-tools`, so the only scheduled workflow is `upstream-watch`
  (GitHub runs schedules from the default branch alone).
- Leave the fork's `main` alone (no "Sync fork" button): a push to `main` runs upstream's CI,
  CodeQL, coverage and scorecard workflows in the fork. Nothing here needs the fork's `main`;
  fix branches start from `upstream/main` locally.
- Pushing `fix/*` branches runs nothing: upstream's push-triggered workflows only watch `main`,
  `release` and version tags.
- In `mailcraft/`, the `upstream` remote can fetch but not push.

## Making a fix

1. File the upstream problem report, or find the existing one:
   <https://github.com/UCS-Care-Group/mailcraft/issues/new?template=problem.yml>
   It is public: no real mail, names or addresses.
2. `.\New-Patch.ps1 -Issue 1464 -Slug custom-font-colour`
   creates `fix/1464-custom-font-colour` from `upstream/main` in `mailcraft/` and registers it.
3. In `mailcraft/`, make **two commits**:
   1. **The regression test alone**, in a file of its own (`tests.rs`, `<name>_tests.rs` or
      `tests/`, brought in with `#[cfg(test)] mod <name>_tests;`; upstream rejects inline test
      modules). It must fail on upstream as it is.
   2. **The fix**, with its release-notes line in
      `packaging/release-notes.d/fixes/<issue>.md` (see that folder's README).

   Commit messages follow upstream's style. If an AI helped, end the message with
   `Human-reviewed, AI-assisted, nobody's mailbox harmed.` (no `Co-Authored-By`).
4. `cargo xtask ci` must pass (in `mailcraft/`; set `MAILCRAFT_REPORT_URL=` empty when you run the app).
5. `.\Submit-Patch.ps1 -Id custom-font-colour -TestCmd 'cargo test -p mailcraft-html font_colour'`
   checks the test fails without the fix and passes with it, pushes the branch to your fork,
   and opens a **draft** pull request upstream with `Closes #<issue>`. Read it on GitHub, mark it
   ready, and on your first pull request sign the CLA by commenting:
   `I have read the MailCraft CLA and I agree to it.` (only you can sign it).
6. `.\Sync-Patches.ps1` to rebuild your copy with the new fix in it. Only one of `Submit-Patch.ps1`
   and `Sync-Patches.ps1` runs at a time; the second says so and stops.

The test-first commit is what makes step 3 of the sync work: it lets the sync ask "does the
bug still happen on the new upstream, without my fix?".

## When upstream releases

```powershell
.\Sync-Patches.ps1             # check every fix, rebuild doug/patched, tag patched/vX.Y.Z-doug.N
.\Sync-Patches.ps1 -DryRun     # only check and write the report
.\Sync-Patches.ps1 -Base main  # build on upstream/main instead of the latest release
.\Sync-Patches.ps1 -Recheck    # run every fix's regression test again, even one whose result stands
.\Sync-Patches.ps1 -FullCi     # check the build with cargo xtask ci instead of the workspace tests
```

Each fix that is not deprecated is checked in this order:

1. **Merged pull request**: your PR is merged and the build base contains it: `merged`.
2. **Identical change**: `git cherry` finds every commit already upstream: `merged`.
3. **Fixed another way**: your regression test alone, applied to the new upstream, passes: `superseded`.
4. **Issue state**: added as evidence; "closed as not planned" means upstream won't take it, so keep the fix yourself.
5. **Still needed**: the fix applies to the new upstream (`active`, built in) or doesn't (`conflict`,
   left out of the build until you rebase the branch).

The result is in `reports/<tag>.md` (the script exits with code 2 when something needs you).
Then, once you agree with it:

```powershell
.\Retire-Patch.ps1 -All        # archive, delete branch, close PR if open, mark deprecated
```

## Keeping syncs fast

A sync after a fix changes should take minutes, not hours. What keeps it that way:

- **Its own build folders, on the E: Dev Drive.** Cargo names a workspace crate's output by its
  path within the workspace, so two MailCraft checkouts building in one folder overwrite each
  other's crates, and one can link the other's (a build that "can't find" a function the tree has).
  Only `mailcraft-patched` builds in `E:\cargo\sync\patched`, so it stays incremental; the scratch
  checks build in `scratch\`. **Agents and hand builds never use the scripts' build folders**:
  give each checkout its own `CARGO_TARGET_DIR`. If E: is unavailable, set `target_dir` and
  `scratch_path` to `C:\cargo\sync` and `C:\cargo\sync-tmp` and expect one cold build.
- **One script at a time.** `Sync-Patches.ps1` and `Submit-Patch.ps1` take `.patch-tools.lock`; a
  second one refuses to start ("Another patch script is running") instead of racing the first.
- **Check 3 runs only when something changed.** A fix's regression test is run on the build base
  again only when the base, its test commit or its `test_cmd` changed (`check_key` in
  `patches.toml`). `-Recheck` runs them all.
- **One reused scratch checkout.** The checks and the `doug/patched` assembly share
  `E:\cargo\sync-tmp\check`. That path stays fixed, because Cargo's fingerprints hold absolute
  source paths. Git only rewrites files that differ, so unchanged files keep their timestamps.
  `doug/patched` is then checked out in one step, and cargo rebuilds only what changed.
- **The build is checked with the workspace tests** (`cargo nextest run --locked --workspace` when
  nextest is installed, otherwise `cargo test --locked --workspace`): each fix already passed
  `cargo xtask ci` on its own branch. `-FullCi` runs `cargo xtask ci` instead.

The first sync with an empty `E:\cargo\sync` compiles everything once (debug and release).

## Automatic watch

`.github/workflows/upstream-watch.yml` runs daily on the fork. When upstream has a release that
has no report issue yet, it runs `Sync-Patches.ps1 -DryRun` against it (changing nothing) and opens
an issue in the fork titled `Upstream vX.Y.Z: patch report` with the report, so GitHub notifies
you. It only sees fix branches that have been pushed to the fork (Submit-Patch.ps1 pushes them)
and the `patches.toml` committed on `patch-tools`, so push `patch-tools` after changing it.
Run it by hand from the fork's Actions tab (`force` re-reports a release).

## Rust version

Upstream's CI pins a Rust version in `.github/workflows/ci.yml` (1.98.1 at v0.13.0). The scripts
read it from the checkout they build and set `RUSTUP_TOOLCHAIN` to it, installing it with rustup
if needed; a newer stable brings clippy lints upstream doesn't run, and `cargo xtask ci` then fails
on code upstream considers clean. Working by hand in `mailcraft/`, do the same:
`$env:RUSTUP_TOOLCHAIN = '1.98.1'` (or whatever `ci.yml` says).

## Registry

`patches.toml` lists every fix, with the meaning of each field at the top of the file.
`status` moves `active` -> `merged` / `superseded` (sync) -> `deprecated` (retire), or
`active` <-> `conflict`.

## Fixing a conflict

A fix is made on upstream/main, and a release tag can be far behind it. When the branch doesn't
apply to the release being built, make a backport for that release: a branch named
`backport/<release tag>/<fix branch>`, made from the tag, with the fix's commits picked and the
conflicts resolved. Sync uses it for that release only (and still checks the fix branch first).

```powershell
cd ..\mailcraft
git switch -c backport/v0.13.0/fix/1314-popout-minimized-main v0.13.0
git cherry-pick -x <test commit> <fix commit>   # resolve, git add, git cherry-pick --continue
git push origin backport/v0.13.0/fix/1314-popout-minimized-main
```

When the branch itself conflicts with upstream/main (so the pull request does too), rebase it:

```powershell
cd ..\mailcraft
git switch fix/1464-custom-font-colour
git rebase upstream/main          # keep the test commit first
cargo xtask ci
git push --force-with-lease
cd ..\mailcraft-patches
.\Submit-Patch.ps1 -Id custom-font-colour -NoPr   # re-checks the test, records the new test commit
.\Sync-Patches.ps1
```

When two active fixes apply cleanly to the build base on their own (so each upstream pull request is
clean) yet touch the same lines as each other in `doug/patched`, keep both `fix/*` branches based on
`upstream/main` and make a stack branch `stack/<fix branch>` on top of the earlier active fixes in
`doug/patched`, picking the later fix's commits and resolving the overlap:

```powershell
cd ..\mailcraft
git switch -c stack/fix/1797-builtin-spelling doug/patched
git cherry-pick -x upstream/main..fix/1797-builtin-spelling   # resolve, git add, git cherry-pick --continue
git push origin stack/fix/1797-builtin-spelling
```
