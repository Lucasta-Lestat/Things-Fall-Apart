# Git LFS for map art

2026-11-01, TG roadmap package P3-C (user decision 5). Branch `p3-lfs-tfa`, on top of `335c18bd`. Two commits move the art, and this doc follows them:

1. `3786c3ce` adds the patterns to `tfa-simultaneous-gemini-1/.gitattributes`, after `* text=auto eol=lf`:
   ```
   Maps/tg_*.png filter=lfs diff=lfs merge=lfs -text
   Maps/combat_test*.png filter=lfs diff=lfs merge=lfs -text
   ```
2. `8889d695` runs `git add --renormalize` on exactly the 47 tracked PNGs those patterns match (439,047,712 bytes). They include the `*_roofs.png`, `*_structures.png` and `*_curtain_under.png` overlays.

What stays in plain git: every `*.png.import`, every `*_cells.json`, and every other PNG under `Maps/` (the hand-painted maps, their masks, `Example Maps/`, `_refs/`). Don't LFS-track `.import` files: Godot rewrites them, and the TG gate reads them as text.

**Forward-only.** History was not rewritten. The old PNG blobs stay in the pack, so the repo stops growing by a full PNG per art change but doesn't shrink. A rewrite would need a force-push, and happens only if you ask for it.

**Nothing is pushed.** See [Hosting quota](#hosting-quota-read-before-the-first-push).

## How it works

The index and the commits hold a pointer of about 130 bytes per PNG (129-133 here):

```
version https://git-lfs.github.com/spec/v1
oid sha256:13a636f7cd73563d2e8e1c5be6014fd14dc48da088cb4e3ce79eec38b1629971
size 34214834
```

The real file lives in `.git/lfs/objects/<oid>`. On checkout, the smudge filter writes the real PNG into the working tree. On `git add`, the clean filter turns it back into a pointer. Godot, tgmap and every tool only ever see the working-tree file, so nothing changes for them while the smudge works. The `.godot` import cache is unaffected too, because the PNG bytes are the same.

## Setup

### Per clone

git-lfs ships with Git for Windows; this machine has git-lfs 3.3.0. Check it with `git lfs version`.

1. Once per user and machine, run `git lfs install`. It writes the `filter.lfs.*` config into the global git config. This machine already has it.
2. Clone as usual. With the filter configured, `git clone` downloads the art of the commit it checks out.
3. Inside the new clone, run `git lfs install --local`. It writes the filter into the clone's `.git/config` and installs its hooks: `post-checkout`, `post-commit`, `post-merge` and `pre-push`. This repo's were installed that way on 2026-11-01. Without the `pre-push` hook, a push sends the commits but not their LFS objects.
4. A clone made without the filter, or with `GIT_LFS_SKIP_SMUDGE=1`, holds pointer files. Run `git lfs pull` in it.
5. `git lfs env` shows where the objects go (`LocalMediaDir`) and the remote (`Endpoint`).

A fresh clone downloads the current art (about 440 MB) on top of the git history, which still holds the old PNG blobs.

### Per worktree

Nothing to do. Worktrees share the main checkout's `.git`: its config, its hooks and **its LFS store, `.git/lfs/objects`**. The Claude worktrees under `.claude/worktrees/` all use the same store (`git lfs env` in any of them shows `LocalMediaDir=C:\dev\Things-Fall-Apart-Local\.git\lfs\objects`).

- `git worktree add`, `git switch` and `git merge` smudge from that shared store, so no object is downloaded twice and nothing needs the network while the objects are local.
- Run Godot's `--headless --import` after switching a worktree to a branch with other art, as for any branch switch.
- Don't delete `.git/lfs`. Until a push, the shared store is the ONLY copy of the art for the LFS commits.

### The store grows with uncommitted art

The first time git looks at a changed LFS file (`git add`, `git diff`, `git status`), the clean filter hashes it and stores a copy in `.git/lfs/objects`, whether or not it is ever committed. Every export attempt that rewrites the map PNGs in a worktree adds their full size (about 440 MB when every map is re-exported), and an abandoned train leaves it behind.

`git lfs prune` deletes the objects that nothing it keeps references. It keeps the objects of every worktree's checkout, stashes, recent branches and commits, and every commit that has not been pushed. It does not read the reflog, so an object that only an orphaned commit references (an amended commit, a deleted branch) is deleted. Look first:

```sh
git lfs prune --dry-run --verbose
```

It also deletes old versions that have been pushed; those are downloaded again when needed.

## Pointer files: detecting a smudge failure

A smudge failure leaves the pointer text (about 130 bytes) in the working tree where the PNG should be. Typical causes: a clone or worktree made with `GIT_LFS_SKIP_SMUDGE=1` (often the workaround when a smudge errors out), git-lfs missing on a machine, or objects that can't be downloaded: never pushed (a clone on another machine), or refused once the bandwidth quota is used up.

**The PNG itself looks clean.** When the smudge fails at checkout, git records the pointer it wrote, so `git status` doesn't list the PNG.

**Godot's import over a pointer exits 0.** Checked on Godot 4.6 (a throwaway project, 2026-11-01): `--headless --import` returns 0 and logs

```
ERROR: Error importing 'res://Maps/tg_x.png'.
```

It then rewrites the tracked `Maps/<file>.png.import`: `valid=false` takes the place of `path=` and `dest_files`. **That `.import` does show in `git status`. Never commit it**: every checkout would load the map without that texture. The old `.ctex` stays in `.godot/imported`, so an editor that had already imported the map can look normal until it re-imports.

Symptoms:

- `git status` lists a `Maps/tg_*.png.import` or `Maps/combat_test*.png.import` that you didn't change, and its diff adds `valid=false`.
- An import log has `Error importing 'res://Maps/...'`. Grep the log: the exit code is 0 either way.
- The map loads without its ground, structures or roofs.
- The PNG is about 130 bytes, and `head -c 40 Maps/tg_hillside_lower.png` prints `version https://git-lfs.github.com/spec/`.
- tgmap (TG `tools/tgmap.py`) refuses to run with a message that names the file. It checks every PNG of the selected maps in the target's `Maps/`, every PNG in that `Maps/` when the run imports the target, and every file it copies into its sandbox. It checks before anything runs, before the sandbox copy, before the splice and before the import. Its import step also fails on an `Error importing` line for a `Maps/` file.

These commands check for it, run from `tfa-simultaneous-gemini-1/` unless noted:

```sh
git lfs fsck                           # every LFS object of HEAD is present and hashes right
git lfs fsck --pointers                # a file that should be a pointer is not (see Merges below)
for f in Maps/tg_*.png Maps/combat_test*.png; do
  head -c 23 "$f" | grep -q '^version https://git-lfs' && echo "POINTER $f"
done
grep -n "Error importing" <the import log>
```

`git lfs ls-files` marks each file `*` (the real file) or `-` (a pointer), but run it from the repo root. Its marker checks the root-relative path, so from `tfa-simultaneous-gemini-1/` every line shows `-`.

The fix, in this order (checked on the same throwaway project):

1. `git lfs checkout` when the objects are in the local store (always the case on this machine until something deletes them), or `git lfs pull` to download them (only once they have been pushed).
2. `git checkout -- Maps/<file>.png.import` for every `.import` an import rewrote to `valid=false`.
3. Run Godot's `--headless --import`. The `.md5` in `.godot/imported` still holds the pointer's md5, so Godot re-imports the PNG, and the `.import` comes back exactly as committed.

## Merges with branches cut before the LFS commits

A branch cut before `8889d695` holds raw blobs for these paths. That matters when it **changes or adds any file matching the patterns** (`Maps/tg_*.png`, `Maps/combat_test*.png`): a new map, a re-exported map, P3-A's companion images.

- A file the branch **adds** merges with no conflict and lands as a raw blob. Git LFS may print `Encountered 1 file that should have been a pointer, but wasn't` during the merge. `git status` may or may not list the file, so neither one is a check.
- A file the branch **changes** conflicts with the pointer. Take the branch's PNG in the working tree, then `git add` it; the clean filter turns it into a pointer.

After merging any branch cut before `8889d695`, from `tfa-simultaneous-gemini-1/`:

1. Run `git lfs fsck --pointers`. For each raw blob it prints `pointer: unexpectedGitObject: "<path>" ... should have been a pointer but was not`, and it exits 1.
2. If it lists files, run `git add --renormalize -- 'Maps/tg_*.png' 'Maps/combat_test*.png'` and commit. (Each pattern must match a tracked file, or `git add` stops and adds nothing. Both match in this repo.)
3. Run `git lfs fsck --pointers` again. It must print `Git LFS fsck OK`.

Checked on a throwaway repo on 2026-11-01. Branches that don't touch these paths merge as usual.

## Hosting quota (read before the first push)

GitHub meters Git LFS **storage** and **bandwidth** per account. **Every pushed version of every LFS file is kept**: deleting a branch or a commit doesn't free the storage, and removing pushed LFS objects is not an ordinary git operation on GitHub.

- The first push of `8889d695` uploads the whole set: about 435-500 MB (439 MB today).
- Each Perrow art train re-exports the six tg_hillside_* maps' PNGs and adds about 350-450 MB of new versions. A legacy art round adds its own share.
- Every fresh clone, and every `git lfs pull` of new art, counts against the bandwidth.

Before pushing, check the account's current LFS allowance (GitHub Settings, Billing, Git LFS data). Then budget data packs, or a lower train cadence.

## Pushing is your call

No tool or agent pushes:

- tgmap never pushes.
- The TG roadmap's trains commit locally.
- LFS objects go up only when a train ships and you push.

The `pre-push` hook uploads the LFS objects of the commits being pushed, so a `git push` of any branch that contains `8889d695` is the ~440 MB upload. To see what a push would upload without sending anything:

```sh
git lfs push --dry-run origin <branch>
```
