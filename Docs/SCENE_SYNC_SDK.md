# Scene Sync SDK

## Source of truth

The Scene Sync Godot addon is developed in [`afjk/afjk.jp`](https://github.com/afjk/afjk.jp), not in this repository.

- Repository: `https://github.com/afjk/afjk.jp.git`
- Source path: `godot/addons/scene_sync`
- Pinned commit: `a2fcdb5cce6e73e40704334625f6d616247b3885`
- Addon version: `0.2.0`
- Vendor destination: `addons/scene_sync`

The complete source subtree is vendored, including the C# Loomlet runner,
`LoomletRuntime`, Godot `.uid` files, and editor plugin files. The exact pin and
source tree object are recorded in `scene-sync-version.txt`.

Do not patch files below `addons/scene_sync` directly. Fix SDK defects in
`afjk/afjk.jp` first, then update this repository to the resulting commit.

## Updating

The update script accepts only a full 40-character commit SHA. From the
repository root, run:

```sh
scripts/update_scene_sync_addon.sh <40-character-commit-sha>
```

With no SHA argument, the script re-vendors the commit recorded in
`scene-sync-version.txt`:

```sh
scripts/update_scene_sync_addon.sh
```

For an offline update or script test, point it at a local clone:

```sh
scripts/update_scene_sync_addon.sh <40-character-commit-sha> \
  --source-repo ../afjk.jp
```

The script checks only `addons/scene_sync` and `scene-sync-version.txt` for
local changes. Unrelated worktree changes do not block an update. It retrieves
and validates the commit, source path, addon version, and complete file
manifest in a temporary directory before replacing either managed target.
Files removed upstream are therefore removed locally, while a retrieval or
validation failure leaves the existing vendor and version file intact.

The initial-bootstrap exception applies only when both `addons/scene_sync` and
`scene-sync-version.txt` are absent. If either target already exists, the
script applies the normal dirty check regardless of whether the files are
tracked. A partially copied addon, an untracked version file, or an entirely
untracked vendor tree must therefore be removed or committed before retrying.
Once the targets are tracked, local modifications and untracked files within
them must likewise be committed, reverted, or removed before updating.

Review the resulting addon diff and `scene-sync-version.txt` together. A commit
that changes the addon should never be recorded without the matching vendored
tree.

## Verification

Check shell syntax and confirm the vendored file manifest and contents against
the recorded source commit:

```sh
bash -n scripts/update_scene_sync_addon.sh
scripts/update_scene_sync_addon.sh --source-repo ../afjk.jp
git diff --check
```

For a direct, reliable tree comparison, use a temporary archive and `diff`:

```sh
commit=$(sed -n 's/^commit=//p' scene-sync-version.txt)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
git -C ../afjk.jp archive "$commit" godot/addons/scene_sync | tar -x -C "$tmp_dir"
diff -ru "$tmp_dir/godot/addons/scene_sync" addons/scene_sync
```

Then validate the runtime integration:

1. Open the project with the pinned Godot .NET editor and complete import.
2. Run `dotnet restore` and `dotnet build` for the Godot C# project.
3. Confirm the SceneSync plugin loads without GDScript or C# errors.
4. Export an Android arm64 Debug APK with the matching .NET export templates.
5. Join the same room as the Web viewer and test `scene-state`, add, transform,
   remove, reconnect, GLB orientation, and Loomlet graph evaluation.
