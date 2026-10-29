#!/usr/bin/env bash
# Publishes the GitHub release for an existing tag `v<version>`:
# checks the tag against build.zig.zon and CHANGELOG.md, checks that
# `zig fetch` of the tag yields the same package hash as the checked-out
# tree, and uses the CHANGELOG.md section as the release notes.
# Usage: release.sh v0.1.0 (needs zig 0.17.0, gh and GH_TOKEN).
set -euo pipefail

tag=${1:?usage: release.sh v<version>}
version=${tag#v}
repo=${GITHUB_REPOSITORY:-SamuelLHuber/hegel-zig}

zon_version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
if [ "$tag" != "v$zon_version" ]; then
  echo "tag $tag does not match build.zig.zon version $zon_version" >&2
  exit 1
fi

notes=$(awk -v v="$version" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^## \[/ { exit }
  on && /^\[[^]]*\]: / { next }
  on { print }
' CHANGELOG.md | sed '/./,$!d')
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  echo "CHANGELOG.md has no section for [$version]" >&2
  exit 1
fi

local_hash=$(zig fetch . | tail -n 1)
remote_hash=$(zig fetch "git+https://github.com/$repo#$tag" | tail -n 1)
if [ "$local_hash" != "$remote_hash" ]; then
  echo "package hash mismatch: tree $local_hash, tag $remote_hash" >&2
  exit 1
fi

notes_file=$(mktemp)
{
  printf '%s\n\n' "$notes"
  printf '## Install\n\n```sh\nzig fetch --save git+https://github.com/%s#%s\n```\n\n' "$repo" "$tag"
  printf 'Package hash: `%s`\n' "$local_hash"
} > "$notes_file"
cat "$notes_file"

gh release create "$tag" --repo "$repo" --verify-tag --title "hegel-zig $tag" --notes-file "$notes_file"
