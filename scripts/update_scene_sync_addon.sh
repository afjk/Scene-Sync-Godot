#!/usr/bin/env bash

set -euo pipefail

CANONICAL_REPOSITORY="https://github.com/afjk/afjk.jp.git"
SOURCE_PATH="godot/addons/scene_sync"
VENDOR_PATH="addons/scene_sync"
VERSION_FILENAME="scene-sync-version.txt"

usage() {
    cat <<'EOF'
Usage: scripts/update_scene_sync_addon.sh [COMMIT_SHA] [--source-repo REPOSITORY]
       scripts/update_scene_sync_addon.sh --commit COMMIT_SHA [--source-repo REPOSITORY]

COMMIT_SHA must be a full 40-character hexadecimal Git commit SHA. If it is
omitted, the commit is read from scene-sync-version.txt. REPOSITORY defaults to
https://github.com/afjk/afjk.jp.git and may be a local Git checkout for testing.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || \
    die "the script must be run from a Git worktree"
VENDOR_DIR="$REPO_ROOT/$VENDOR_PATH"
VERSION_FILE="$REPO_ROOT/$VERSION_FILENAME"

commit_sha=""
source_repo="$CANONICAL_REPOSITORY"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --commit)
            [ "$#" -ge 2 ] || die "--commit requires a value"
            [ -z "$commit_sha" ] || die "commit SHA was specified more than once"
            commit_sha="$2"
            shift 2
            ;;
        --source-repo)
            [ "$#" -ge 2 ] || die "--source-repo requires a value"
            source_repo="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            die "unknown option: $1"
            ;;
        *)
            [ -z "$commit_sha" ] || die "commit SHA was specified more than once"
            commit_sha="$1"
            shift
            ;;
    esac
done

if [ -z "$commit_sha" ]; then
    [ -f "$VERSION_FILE" ] || die "no commit supplied and $VERSION_FILENAME does not exist"
    commit_sha=$(sed -n 's/^commit=//p' "$VERSION_FILE")
    [ -n "$commit_sha" ] || die "$VERSION_FILENAME does not contain commit=<SHA>"
fi

if ! [[ "$commit_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    die "commit must be exactly 40 hexadecimal characters"
fi
commit_sha=$(printf '%s' "$commit_sha" | tr 'A-F' 'a-f')

# Only a completely absent vendor directory and version file qualify as an
# initial bootstrap. In every other state, tracked and untracked changes below
# either managed target must be resolved before updating.
initial_bootstrap=false
if [ ! -e "$VENDOR_DIR" ] && [ ! -e "$VERSION_FILE" ]; then
    initial_bootstrap=true
fi
if [ "$initial_bootstrap" = false ]; then
    target_status=$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all -- \
        "$VENDOR_PATH" "$VERSION_FILENAME")
    [ -z "$target_status" ] || {
        echo "$target_status" >&2
        die "local changes exist in the vendored addon or version file"
    }
fi

temp_root=$(mktemp -d "$REPO_ROOT/.scene-sync-update.XXXXXX")
replacement_started=false
vendor_existed=false
version_existed=false

cleanup() {
    status=$?
    if [ "$replacement_started" = true ] && [ "$status" -ne 0 ]; then
        if [ -d "$temp_root/old_vendor" ]; then
            rm -rf -- "$VENDOR_DIR"
            mv -- "$temp_root/old_vendor" "$VENDOR_DIR"
        elif [ "$vendor_existed" = false ]; then
            rm -rf -- "$VENDOR_DIR"
        fi
        if [ -f "$temp_root/old_version" ]; then
            rm -f -- "$VERSION_FILE"
            mv -- "$temp_root/old_version" "$VERSION_FILE"
        elif [ "$version_existed" = false ]; then
            rm -f -- "$VERSION_FILE"
        fi
    fi
    rm -rf -- "$temp_root"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

source_git_dir=""
if git -C "$source_repo" rev-parse --git-dir >/dev/null 2>&1; then
    source_git_dir=$(CDPATH= cd -- "$source_repo" && pwd)
else
    git clone --quiet --filter=blob:none --no-checkout "$source_repo" "$temp_root/source"
    git -C "$temp_root/source" fetch --quiet --depth=1 origin "$commit_sha"
    source_git_dir="$temp_root/source"
fi

resolved_commit=$(git -C "$source_git_dir" rev-parse --verify "$commit_sha^{commit}" 2>/dev/null) || \
    die "commit is not available from source repository: $commit_sha"
[ "$resolved_commit" = "$commit_sha" ] || die "source resolved to an unexpected commit"

git -C "$source_git_dir" cat-file -e "$commit_sha:$SOURCE_PATH/plugin.cfg" 2>/dev/null || \
    die "source addon is missing plugin.cfg at $SOURCE_PATH"

mkdir -p "$temp_root/extract"
git -C "$source_git_dir" archive "$commit_sha" "$SOURCE_PATH" | tar -x -C "$temp_root/extract"
staged_vendor="$temp_root/extract/$SOURCE_PATH"
[ -d "$staged_vendor" ] || die "archive did not contain $SOURCE_PATH"

addon_version=$(sed -n 's/^version="\([^"]*\)"$/\1/p' "$staged_vendor/plugin.cfg")
[ -n "$addon_version" ] || die "could not read addon version from plugin.cfg"
source_tree=$(git -C "$source_git_dir" rev-parse "$commit_sha:$SOURCE_PATH")

git -C "$source_git_dir" ls-tree -r --name-only "$commit_sha" -- "$SOURCE_PATH" \
    | sed "s#^$SOURCE_PATH/##" | LC_ALL=C sort > "$temp_root/source-manifest"
(CDPATH= cd -- "$staged_vendor" && find . \( -type f -o -type l \) -print \
    | sed 's#^\./##' | LC_ALL=C sort) > "$temp_root/vendor-manifest"
cmp -s "$temp_root/source-manifest" "$temp_root/vendor-manifest" || \
    die "extracted addon does not match the source tree manifest"

cat > "$temp_root/new_version" <<EOF
repository=$CANONICAL_REPOSITORY
commit=$commit_sha
source_path=$SOURCE_PATH
source_tree=$source_tree
addon_version=$addon_version
EOF

mkdir -p "$REPO_ROOT/addons"
[ -e "$VENDOR_DIR" ] && vendor_existed=true
[ -e "$VERSION_FILE" ] && version_existed=true
replacement_started=true
if [ "$vendor_existed" = true ]; then
    mv -- "$VENDOR_DIR" "$temp_root/old_vendor"
fi
if [ "$version_existed" = true ]; then
    mv -- "$VERSION_FILE" "$temp_root/old_version"
fi

mv -- "$staged_vendor" "$VENDOR_DIR"
mv -- "$temp_root/new_version" "$VERSION_FILE"
replacement_started=false

echo "Vendored Scene Sync addon $addon_version at $commit_sha"
