#!/bin/bash
set -euo pipefail
umask 077

# LimaのLinuxゲストで製品をビルドし、転送できる検証済みtar.gzを作る。
if [ "$#" -ne 3 ] || [ "$(uname -s)" != Linux ]; then
    printf '%s\n' 'Usage in Linux: Publish-PrunletLinux.sh <new absolute output directory> <source commit|--preview> <linux-x64|linux-arm64>' >&2
    exit 2
fi
source_root="$(cd "$(dirname "$0")/.." && pwd -P)"
output="$1"
commit="$2"
runtime="$3"
case "$runtime" in
    linux-arm64) target=aarch64-unknown-linux-gnu; machine=AArch64 ;;
    linux-x64) target=x86_64-unknown-linux-gnu; machine='Advanced Micro Devices X86-64' ;;
    *) printf '%s\n' 'Unsupported Linux runtime.' >&2; exit 2 ;;
esac
case "$output" in
    /*) ;;
    *) printf '%s\n' 'Output directory must be absolute.' >&2; exit 2 ;;
esac
parent="$(dirname "$output")"
if [ "$(cd "$parent" && pwd -P)" != "$parent" ] || [ -e "$output" ] || [ -L "$output" ]; then
    printf '%s\n' 'Use a new output directory under an existing physical parent.' >&2
    exit 2
fi
case "$output/" in
    "$source_root/"*) printf '%s\n' 'Output must be outside the source tree.' >&2; exit 2 ;;
esac
if [ "$commit" = --preview ]; then
    commit=development
    asset="prunlet-preview-$runtime.tar.gz"
else
    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]] ||
        [ "$(git -C "$source_root" rev-parse HEAD)" != "$commit" ] ||
        [ -n "$(git -C "$source_root" status --porcelain --untracked-files=normal)" ]; then
        printf '%s\n' 'The source checkout is not the expected clean commit.' >&2
        exit 2
    fi
    asset="prunlet-$runtime.tar.gz"
fi
toolchain="$(tr -d '\r' < "$source_root/rust-toolchain.toml" | sed -n 's/^channel = "\([^"]*\)"$/\1/p')"
[[ "$toolchain" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
actual_toolchain="$(rustc --version)"
[[ "$actual_toolchain" == "rustc $toolchain "* ]]
version="$(tr -d '\r' < "$source_root/Cargo.toml" | sed -n 's/^version = "\([^"]*\)"$/\1/p')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]

if [ "$runtime" = linux-x64 ] && [ "$(uname -m)" = aarch64 ]; then
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc
    export CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc
    export AR_x86_64_unknown_linux_gnu=x86_64-linux-gnu-ar
fi
mkdir "$output" "$output/tmp" "$output/publish"
export TMPDIR="$output/tmp" CARGO_TARGET_DIR="$output/target" PRUNLET_SOURCE_COMMIT="$commit"
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
cd "$source_root"
cargo build --locked --release --target "$target" --bin prunlet
if [ "$commit" != development ]; then
    [ "$(git rev-parse HEAD)" = "$commit" ]
    [ -z "$(git status --porcelain --untracked-files=normal)" ]
fi
exe="$output/publish/prunlet"
install -m 755 "$CARGO_TARGET_DIR/$target/release/prunlet" "$exe"
LC_ALL=C readelf -h "$exe" | grep -Eq "^[[:space:]]*Machine:[[:space:]]*$machine$"
if LC_ALL=C grep -aq 'PRUNLET_LINUX_UPDATE_FIXTURE' "$exe"; then
    printf '%s\n' 'The Linux release contains a fixture transport.' >&2
    exit 1
fi
sha="$(sha256sum "$exe")"
size="$(stat -c %s "$exe")"
manifest="$output/publish/manifest.json"
printf '{"version":"%s","commit":"%s","runtime":"%s","bytes":%s,"sha256":"%s"}\n' \
    "$version" "$commit" "$runtime" "$size" "${sha%% *}" > "$manifest"
chmod 644 "$manifest"
archive="$output/$asset"
tar --format=ustar -czf "$archive" -C "$output/publish" prunlet manifest.json
[ "$(tar -tzf "$archive")" = "$(printf 'prunlet\nmanifest.json\n')" ]
tar -xOzf "$archive" prunlet | cmp -- "$exe" -
tar -xOzf "$archive" manifest.json | cmp -- "$manifest" -
[ "$(stat -c %s "$archive")" -le 67108864 ] && [ "$size" -le 67108864 ]
archive_sha="$(sha256sum "$archive")"
printf '%s  %s\n' "${archive_sha%% *}" "$asset" > "$archive.sha256"
printf '%s\n' "$archive"
