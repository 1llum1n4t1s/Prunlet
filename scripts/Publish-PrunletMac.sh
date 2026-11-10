#!/bin/bash
set -euo pipefail
umask 077

# Apple Silicon実機で固定済みソースをビルドし、署名・公証後の公開ZIPを生成する。
if [ "$#" -ne 2 ] || [ "$(uname -sm)" != "Darwin arm64" ]; then
    printf '%s\n' 'Usage on Apple Silicon: Publish-PrunletMac.sh <new absolute output directory> <source commit>' >&2
    exit 2
fi
source_root="$(cd "$(dirname "$0")/.." && pwd -P)"
output="$1"
commit="$2"
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
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]] ||
    [ "$(git -C "$source_root" rev-parse HEAD)" != "$commit" ] ||
    [ -n "$(git -C "$source_root" status --porcelain --untracked-files=normal)" ]; then
    printf '%s\n' 'The source checkout is not the expected clean commit.' >&2
    exit 2
fi
: "${PRUNLET_MACOS_TEAM_ID:?Set the Developer ID team}"
: "${PRUNLET_MACOS_SIGN_IDENTITY:?Set the Developer ID Application identity}"
: "${PRUNLET_MACOS_KEYCHAIN:?Set the signing keychain path}"
: "${PRUNLET_MACOS_NOTARY_PROFILE:?Set the notarytool keychain profile}"
[ "$PRUNLET_MACOS_TEAM_ID" = "SL228Y8UUR" ]

mkdir "$output" "$output/tmp"
export TMPDIR="$output/tmp" CARGO_TARGET_DIR="$output/target" PRUNLET_SOURCE_COMMIT="$commit"
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
cd "$source_root"
cargo build --locked --release --target aarch64-apple-darwin --bin prunlet
exe="$output/prunlet"
cp "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/prunlet" "$exe"
[ "$(lipo -archs "$exe")" = "arm64" ]
codesign --force --sign "$PRUNLET_MACOS_SIGN_IDENTITY" --keychain "$PRUNLET_MACOS_KEYCHAIN" \
    --options runtime --timestamp --identifier com.kagayoi.prunlet "$exe"
codesign --verify --strict "$exe"
ditto -c -k "$exe" "$output/notarization-input.zip"
xcrun notarytool submit "$output/notarization-input.zip" --keychain "$PRUNLET_MACOS_KEYCHAIN" \
    --keychain-profile "$PRUNLET_MACOS_NOTARY_PROFILE" --wait --output-format json > "$output/notarization.json"
status="$(/usr/bin/plutil -extract status raw "$output/notarization.json")"
if [ "$status" != "Accepted" ]; then
    printf '%s\n' 'Notarization did not return Accepted.' >&2
    exit 1
fi
"$exe" --package-macos-release "$output/prunlet-update-osx-arm64.zip" > "$output/package.json"
expected="$(/usr/bin/plutil -extract sha256 raw "$output/package.json")"
actual="$(shasum -a 256 "$output/prunlet-update-osx-arm64.zip")"
[ "${actual%% *}" = "$expected" ]
cat "$output/package.json"
