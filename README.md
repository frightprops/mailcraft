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
| `mailcraft-target/` | Shared Cargo target folder, so dependencies are compiled once. |
| `mailcraft-builds/<tag>/` | Finished `mailcraft.exe` and `mailcraft-cli.exe` for each build tag. |

## Branches

- `main`: mirrors `upstream/main`. Never commit to it.
- `fix/<issue>-<slug>`: one per bug, based on `upstream/main` (upstream only accepts pull requests
  based on `main`), and opened as a pull request upstream.
- `doug/patched`: the latest upstream release tag plus the commits of every fix still needed.
  It is recreated from scratch on each sync, never merged forward.
- `patch-tools`: this branch.
- Tags `vX.Y.Z-doug.N`: your builds. Tags `archive/fix/...`: retired fixes, kept for reference.

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
6. `.\Sync-Patches.ps1` to rebuild your copy with the new fix in it.

The test-first commit is what makes step 3 of the sync work: it lets the sync ask "does the
bug still happen on the new upstream, without my fix?".

## When upstream releases

```powershell
.\Sync-Patches.ps1             # check every fix, rebuild doug/patched, tag vX.Y.Z-doug.N
.\Sync-Patches.ps1 -DryRun     # only check and write the report
.\Sync-Patches.ps1 -Base main  # build on upstream/main instead of the latest release
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
