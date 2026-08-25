#!/usr/bin/env bash

set -euo pipefail

UPSTREAM_REPOSITORY="https://github.com/shiena/godot-gsplat.git"
UPSTREAM_COMMIT="dfc8df4893f0f6e26c847590ff1669fa8404da6d"
EXPECTED_RUSTC="1.94.0"
EXPECTED_CARGO_NDK="4.1.2"
EXPECTED_ANDROID_NDK="28.1.13356709"

usage() {
    cat <<'EOF'
Usage: scripts/build_godot_gsplat_android.sh --ndk PATH [options]

Options:
  --ndk PATH          Android NDK 28.1.13356709 root (required)
  --source-repo REPO  Upstream Git repository or local checkout
  --output FILE       Output .so path (default: build/native/godot-gsplat/...)
  -h, --help          Show this help

The script checks out the pinned upstream commit in a temporary directory,
applies the repository-pinned Cargo.lock and compatibility patch, and builds
the Android arm64 release library with cargo-ndk.
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

android_ndk=""
source_repo="$UPSTREAM_REPOSITORY"
output_file="$REPO_ROOT/build/native/godot-gsplat/android-arm64/libgodot_gsplat.so"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ndk)
            [ "$#" -ge 2 ] || die "--ndk requires a value"
            android_ndk="$2"
            shift 2
            ;;
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

[ -n "$android_ndk" ] || die "--ndk is required"
[ -d "$android_ndk/toolchains/llvm/prebuilt" ] || die "invalid Android NDK: $android_ndk"
[ "$(basename -- "$android_ndk")" = "$EXPECTED_ANDROID_NDK" ] || \
    die "Android NDK must be $EXPECTED_ANDROID_NDK"
[ -f "$LOCK_FILE" ] || die "missing pinned Cargo.lock: $LOCK_FILE"
[ -f "$PATCH_FILE" ] || die "missing compatibility patch: $PATCH_FILE"
command -v cargo >/dev/null 2>&1 || die "cargo is required"
cargo ndk --version | grep -Fq "cargo-ndk $EXPECTED_CARGO_NDK" || \
    die "cargo-ndk $EXPECTED_CARGO_NDK is required"
rustc --version | grep -Fq "rustc $EXPECTED_RUSTC" || \
    die "rustc $EXPECTED_RUSTC is required"

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/scene-sync-godot-gsplat.XXXXXX")
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

(
    cd "$temp_root/source"
    ANDROID_NDK_HOME="$android_ndk" \
    CARGO_HOME="$temp_root/cargo-home" \
    CARGO_INCREMENTAL=0 \
    CARGO_TARGET_DIR="$temp_root/target" \
    RUSTFLAGS="--remap-path-prefix=$temp_root=/build/godot-gsplat" \
    SOURCE_DATE_EPOCH="$source_date_epoch" \
        cargo ndk -t arm64-v8a build --release --locked
)

built_library="$temp_root/target/aarch64-linux-android/release/libgodot_gsplat.so"
[ -s "$built_library" ] || die "Android library was not produced"
file "$built_library" | grep -Fq "ELF 64-bit LSB shared object, ARM aarch64" || \
    die "built library is not an AArch64 ELF shared object"

prebuilt_dir=$(find "$android_ndk/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 \
    -type d -print -quit)
[ -n "$prebuilt_dir" ] || die "NDK LLVM prebuilt directory was not found"
"$prebuilt_dir/bin/llvm-nm" -D "$built_library" \
    | grep -F " gdext_rust_init" >/dev/null || \
    die "built library does not export gdext_rust_init"

mkdir -p -- "$(dirname -- "$output_file")"
cp -- "$built_library" "$output_file"
echo "Built godot-gsplat Android arm64 at $output_file"
shasum -a 256 "$output_file"
