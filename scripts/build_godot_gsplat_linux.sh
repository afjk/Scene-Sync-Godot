#!/usr/bin/env bash

set -euo pipefail

UPSTREAM_REPOSITORY="https://github.com/shiena/godot-gsplat.git"
UPSTREAM_COMMIT="dfc8df4893f0f6e26c847590ff1669fa8404da6d"
RUST_IMAGE="rust:1.94.0-bookworm@sha256:365468470075493dc4583f47387001854321c5a8583ea9604b297e67f01c5a4f"

usage() {
    cat <<'EOF'
Usage: scripts/build_godot_gsplat_linux.sh [options]

Options:
  --source-repo REPO  Upstream Git repository or local checkout
  --output FILE       Output .so path (default: build/native/godot-gsplat/...)
  -h, --help          Show this help

The script checks out the pinned upstream commit in a temporary directory,
applies the repository-pinned Cargo.lock and compatibility patch, and builds
the Linux x86_64 release library in the pinned Rust container image.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || \
    die "the script must be run from a Git worktree"
LOCK_FILE="$SCRIPT_DIR/third_party/godot-gsplat-Cargo.lock"
PATCH_FILE="$SCRIPT_DIR/third_party/godot-gsplat-push-constant-padding.patch"

source_repo="$UPSTREAM_REPOSITORY"
output_file="$REPO_ROOT/build/native/godot-gsplat/linux-x86_64/libgodot_gsplat.so"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-repo)
            [ "$#" -ge 2 ] || die "--source-repo requires a value"
            source_repo="$2"
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || die "--output requires a value"
            output_file="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[ -f "$LOCK_FILE" ] || die "missing pinned Cargo.lock: $LOCK_FILE"
[ -f "$PATCH_FILE" ] || die "missing compatibility patch: $PATCH_FILE"
command -v docker >/dev/null 2>&1 || die "Docker is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not available"

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/scene-sync-godot-gsplat-linux.XXXXXX")
cleanup() {
    status=$?
    rm -rf -- "$temp_root"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if git -C "$source_repo" rev-parse --git-dir >/dev/null 2>&1; then
    git clone --quiet --no-checkout "$source_repo" "$temp_root/source"
else
    git clone --quiet --filter=blob:none --no-checkout "$source_repo" "$temp_root/source"
fi
if ! git -C "$temp_root/source" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null; then
    git -C "$temp_root/source" fetch --quiet --depth=1 origin "$UPSTREAM_COMMIT"
fi
git -C "$temp_root/source" checkout --quiet --detach "$UPSTREAM_COMMIT"

resolved_commit=$(git -C "$temp_root/source" rev-parse HEAD)
[ "$resolved_commit" = "$UPSTREAM_COMMIT" ] || die "unexpected upstream commit: $resolved_commit"
source_date_epoch=$(git -C "$temp_root/source" show -s --format=%ct HEAD)

cp -- "$LOCK_FILE" "$temp_root/source/Cargo.lock"
git -C "$temp_root/source" apply --check "$PATCH_FILE"
git -C "$temp_root/source" apply "$PATCH_FILE"
mkdir -p -- "$temp_root/target" "$temp_root/cargo-home"

docker run --platform linux/amd64 --rm \
    --user "$(id -u):$(id -g)" \
    --env CARGO_HOME=/build/godot-gsplat/cargo-home \
    --env CARGO_INCREMENTAL=0 \
    --env CARGO_TARGET_DIR=/build/godot-gsplat/target \
    --env RUSTFLAGS=--remap-path-prefix=/build/godot-gsplat=/build/godot-gsplat \
    --env SOURCE_DATE_EPOCH="$source_date_epoch" \
    --volume "$temp_root:/build/godot-gsplat" \
    --workdir /build/godot-gsplat/source \
    "$RUST_IMAGE" \
    cargo build --release --locked

built_library="$temp_root/target/release/libgodot_gsplat.so"
[ -s "$built_library" ] || die "Linux library was not produced"
file "$built_library" | grep -Fq "ELF 64-bit LSB shared object, x86-64" || \
    die "built library is not an x86-64 ELF shared object"

docker run --platform linux/amd64 --rm \
    --volume "$built_library:/build/libgodot_gsplat.so:ro" \
    --entrypoint nm \
    "$RUST_IMAGE" \
    -D /build/libgodot_gsplat.so \
    | grep -F " gdext_rust_init" >/dev/null || \
    die "built library does not export gdext_rust_init"

mkdir -p -- "$(dirname -- "$output_file")"
cp -- "$built_library" "$output_file"
echo "Built godot-gsplat Linux x86_64 at $output_file"
shasum -a 256 "$output_file"
