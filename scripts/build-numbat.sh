#!/usr/bin/env bash
# Build the pinned, offline calculator helper for Xcode's selected architectures.
# Requires rustup; called by the app target for direct Xcode and release builds.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$PATH"
ROOT="${SRCROOT:?Run this script through the Invoque Xcode target}"
cd "$ROOT/Numbat"
command -v cargo >/dev/null 2>&1 || {
  echo "error: Numbat requires Rust. Install rustup from https://rustup.rs" >&2
  exit 1
}

export CARGO_TARGET_DIR="$ROOT/build/numbat"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
binaries=()
metadata=()
for arch in ${ARCHS:?Xcode must select at least one architecture}; do
  case "$arch" in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) echo "error: Unsupported Numbat architecture: $arch" >&2; exit 1 ;;
  esac
  cargo build --locked --release --target "$target"
  binaries+=("$CARGO_TARGET_DIR/$target/release/invoque-numbat")
  licenses="$CARGO_TARGET_DIR/$target/licenses.json"
  cargo metadata --locked --format-version 1 --filter-platform "$target" > "$licenses"
  metadata+=("$licenses")
done

HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$HELPERS"
xcrun lipo -create "${binaries[@]}" -output "$HELPERS/invoque-numbat"
chmod +x "$HELPERS/invoque-numbat"

RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$RESOURCES"
python3 "$ROOT/scripts/numbat-licenses.py" "$RESOURCES/Numbat-Licenses.txt" "${metadata[@]}"

# Nested code must be signed before Xcode seals the containing app.
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  signing=(--force --options runtime --sign "$identity")
  if [ "$identity" != - ]; then signing+=(--timestamp); fi
  codesign "${signing[@]}" "$HELPERS/invoque-numbat"
fi
