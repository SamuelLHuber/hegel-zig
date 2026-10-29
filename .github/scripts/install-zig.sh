#!/usr/bin/env bash
# Installs the pinned Zig release, verified against the SHA-256 published in
# https://ziglang.org/download/index.json.
set -euo pipefail

version=0.17.0
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) triple=x86_64-linux sha256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
  Linux-aarch64) triple=aarch64-linux sha256=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
  Darwin-arm64) triple=aarch64-macos sha256=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a ;;
  *) echo "no pinned Zig $version for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

name="zig-$triple-$version"
dest="${RUNNER_TEMP:-/tmp}"
curl --fail --location --retry 3 --silent --show-error \
  --output "$dest/$name.tar.xz" "https://ziglang.org/download/$version/$name.tar.xz"
echo "$sha256  $dest/$name.tar.xz" | shasum -a 256 --check -
tar -xJf "$dest/$name.tar.xz" -C "$dest"
echo "$dest/$name" >> "${GITHUB_PATH:-/dev/null}"
"$dest/$name/zig" version
