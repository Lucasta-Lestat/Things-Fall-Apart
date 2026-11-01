# Git LFS for map art

2026-11-01, TG roadmap package P3-C (user decision 5). Branch `p3-lfs-tfa`, two commits on top of `335c18bd`:

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

The index and the commits hold a 132-byte pointer per PNG:

```
version https://git-lfs.github.com/spec/v1
oid sha256:13a636f7cd73563d2e8e1c5be6014fd14dc48da088cb4e3ce79eec38b1629971
size 34214834
```

The real file lives in `.git/lfs/objects/<oid>`. On checkout, the smudge filter writes the real PNG into the working tree. On `git add`, the clean filter turns it back into a pointer. Godot, tgmap and every tool only ever see the working-tree file, so nothing changes for them while the smudge works. The `.godot` import cache is unaffected too, because the PNG bytes are the same.

## Setup

### Per clone

git-lfs ships with Git for Windows; this machine has git-lfs 3.3.0. Check it with `git lfs version`.

1. Install the hooks and the filter for the repo: `git lfs install --local` (or `git lfs install` once per user, which writes the global config instead). This machine already has the global `filter.lfs.*` config. The repo's hooks were installed with `--local` on 2026-11-01: `post-checkout`, `post-commit`, `post-merge` and `pre-push` in `.git/hooks`.
2. Clone as usual. With the filter configured, `git clone` downloads the art of the commit it checks out.
3. If the clone was made without LFS, or with `GIT_LFS_SKIP_SMUDGE=1`, run `git lfs pull` in it.
4. `git lfs env` shows where the objects go (`LocalMediaDir`) and the remote (`Endpoint`).

A fresh clone downloads the current art (about 440 MB) on top of the git history, which still holds the old PNG blobs.

### Per worktree

Nothing to do. Worktrees share the main checkout's `.git`: its config, its hooks and **its LFS store, `.git/lfs/objects`**. The Claude worktrees under `.claude/worktrees/` all use the same store (`git lfs env` in any of them shows `LocalMediaDir=C:\dev\Things-Fall-Apart-Local\.git\lfs\objects`).

- `git worktree add`, `git switch` and `git merge` smudge from that shared store, so no object is downloaded twice and nothing needs the network while the objects are local.
- Run Godot's `--headless --import` after switching a worktree to a branch with other art, as for any branch switch.
- Don't delete `.git/lfs`. Until a push, the shared store is the ONLY copy of the art for the LFS commits. `git lfs prune` keeps unpushed objects, but deletes old versions, which then have to be downloaded again.

## Pointer files: detecting a smudge failure

A smudge failure leaves the 132-byte pointer text in the working tree where the PNG should be. Typical causes: git-lfs missing from PATH, a clone or worktree made with `GIT_LFS_SKIP_SMUDGE=1`, or an object that was never pushed (a clone on another machine).

**`git status` does not show it.** The pointer in the working tree equals the pointer in the index, so the tree looks clean. Look for these symptoms instead:

- Godot's import fails on a `Maps/tg_*.png` (the file is not a PNG), and the map loads without its ground, structures or roofs.
- The file is about 130 bytes, and `head -c 40 Maps/tg_hillside_lower.png` prints `version https://git-lfs.github.com/spec/`.
- tgmap (TG `tools/tgmap.py`) refuses to run with a message that names this file. It checks every PNG of the selected maps in the target's `Maps/`, and every file it copies into its sandbox, before the sandbox copy, the splice and the import.

These commands check for it, run from `tfa-simultaneous-gemini-1/`:

```sh
git lfs ls-files                       # '*' after the oid = real file, '-' = pointer
git lfs fsck                           # every LFS object of HEAD is present and hashes right
git lfs fsck --pointers                # a file that should be a pointer is not (see Merges below)
for f in Maps/tg_*.png Maps/combat_test*.png; do
  head -c 23 "$f" | grep -q '^version https://git-lfs' && echo "POINTER $f"
done
```

The fix:

- `git lfs checkout` when the objects are in the local store (always the case on this machine until something deletes them).
- `git lfs pull` to download them from the remote (only once they have been pushed).
- Then run Godot's `--headless --import`.

## Merges with branches cut before the LFS commits

A branch cut before `8889d695` that changes one of the 47 PNGs still holds a raw blob for it. Merging it into a main that has the LFS commits conflicts on that file, or lands the raw blob. To fix it:

1. Take the branch's PNG in the working tree.
2. `git add` it; the clean filter turns it into a pointer.
3. Check with `git lfs fsck --pointers` before committing.

Branches that don't touch these PNGs merge as usual.

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
