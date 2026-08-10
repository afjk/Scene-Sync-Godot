# Scene Sync SDK

## Source of truth

The Scene Sync Godot addon is developed in [`afjk/afjk.jp`](https://github.com/afjk/afjk.jp), not in this repository.

- Repository: `https://github.com/afjk/afjk.jp.git`
- Source paths: `godot/addons/scene_sync`, `godot/addons/godot-rapier3d`
- Pinned commit: `7289af0333b4288108adde06ffc5a0dba6852094`
- Addon version: `0.4.0`
- Vendor destinations: `addons/scene_sync`, `addons/godot-rapier3d`

Both complete source subtrees are vendored. This includes the C# Loomlet
runner, `LoomletRuntime`, Godot `.uid` files, editor plugin files, Rapier
GDExtension descriptor, licenses, build provenance, and native libraries. The
exact pin and both source tree objects are recorded in
`scene-sync-version.txt`.

Do not patch files below `addons/scene_sync` or `addons/godot-rapier3d`
directly. Fix SDK defects in the upstream repository first, then update this
repository to the resulting `afjk/afjk.jp` commit.

Version `0.4.0` owns remote URL mesh, image, and text loading, bounded retry,
safe asset-load diagnostics, and animation policy/default-loop handling. It
also preserves GLB source animation order for numeric clip selection while
keeping `clipName` precedence. It also synchronizes scene/object physics and
drives the fixed-timestep `SceneSyncRapierWorld3D` runtime when the native
extension is available. The application must not add a second asset or physics
adapter for the same managed objects.

The Rapier dependency is pinned by upstream to tag
`scenesync-v0.8.28-r0.30.0.3`, commit
`b0578430c3b975bcf3bc0ee86df0450b51a57eb0`, Rapier core `0.30.0`. The
combined release asset is `scenesync-godot-rapier3d-addon.zip` with SHA-256
`90dbbbef3ddfd4e9d6fa34bed713dd1417a2ead70bbde668de6857c131cafbae`.
Its included platforms are macOS universal, Android arm64, Linux x86_64, and
Windows x86_64, and it targets Godot `4.6.3` / extension API `4.6`.

The vendored directory is sourced from `afjk.jp`, not unpacked directly from
the release ZIP. Upstream adds the `source`, `tag`, `asset`, and
`asset_sha256` provenance lines to `SCENESYNC_BUILD.txt` after assembling the
release. Apart from those metadata lines, its descriptor, licenses, signatures,
and four platform binaries match the pinned release asset.

If the GDExtension is missing or unsupported, Scene Sync continues to load and
synchronize physics dictionaries, but reports `rapier-addon-unavailable` and
does not simulate them. This is a safe metadata fallback, not deterministic
physics parity.

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

The script checks only `addons/scene_sync`, `addons/godot-rapier3d`, and
`scene-sync-version.txt` for local changes. Unrelated worktree changes do not
block an update. It retrieves and validates the commit, both source paths,
addon and Rapier build metadata, and both complete file manifests in a
temporary directory before replacing any managed target. Files removed
upstream are therefore removed locally, while a retrieval or validation
failure leaves both existing vendors and the version file intact.

The initial-bootstrap exception applies only when both vendor directories and
`scene-sync-version.txt` are all absent. If any target already exists, the
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
git -C ../afjk.jp archive "$commit" \
  godot/addons/scene_sync godot/addons/godot-rapier3d | tar -x -C "$tmp_dir"
diff -ru "$tmp_dir/godot/addons/scene_sync" addons/scene_sync
diff -ru "$tmp_dir/godot/addons/godot-rapier3d" addons/godot-rapier3d
```

Then validate the runtime integration:

1. Open the project with the pinned Godot .NET editor and complete import.
2. Run `dotnet restore` and `dotnet build` for the Godot C# project.
3. Confirm the SceneSync plugin and `SceneSyncRapierWorld3D` class load without
   GDScript, C#, or native-library errors.
4. Run a fixed-tick Rapier smoke and compare its canonical hash with the
   upstream parity fixture.
5. Export an Android arm64 Debug APK with the matching .NET export templates,
   and verify the APK contains the Rapier Android arm64 `.so`.
6. Join the same room as the Web viewer and test `scene-state`, add, transform,
   remove, reconnect, GLB orientation, and Loomlet graph evaluation.
