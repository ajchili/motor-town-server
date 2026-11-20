#!/usr/bin/env bash
# Install Valve's current steamcmd packages straight from the update manifest.
#
# Why: the documented steamcmd_linux.tar.gz (last changed Jan 2018) contains a
# 2017 bootstrapper that fetches the current manifest successfully (falling back
# from the retired client-download.steampowered.com to media.steampowered.com)
# but then exits 1 without downloading anything, on native x86 hosts as well.
# Installing the packages ourselves and seeding package/ gives steamcmd a modern
# bootstrapper, after which its own self-update works normally.
#
# Every package is checked against the sha2 in the manifest. Valve's zips store
# the binaries as 0666, so executable bits are set explicitly afterwards.
#
# Usage: seed-steamcmd.sh [install dir] [manifest]
#   manifest: steam_cmd_linux (x86_64) or steam_cmd_linuxarm64 (ARM64)
set -euo pipefail
dir="${1:-/opt/steamcmd}"
manifest="${2:-steam_cmd_linux}"
mirror="${STEAMCMD_MIRROR:-https://media.steampowered.com/client}"
mkdir -p "$dir/package"
cd "$dir/package"
curl -fsSL "$mirror/$manifest" -o "$manifest.manifest"
# Parse "file" + "sha2" pairs out of the VDF manifest
awk -F'"' '$2=="file"{f=$4} $2=="sha2"{print f, $4}' "$manifest.manifest" | while read -r file sha; do
  echo "fetch $file"
  curl -fsSL "$mirror/$file" -o "$file"
  echo "$sha  $file" | sha256sum -c --quiet
  unzip -qo "$file" -d "$dir"
  # bootstrapper looks for the package by its base name too
  cp -f "$file" "${file%%.zip.*}.zip"
done
# The ARM64 packages ship only binaries; the steamcmd.sh launcher (which already
# selects linuxarm64 on aarch64) lives in the x86 bootstrap package. Borrow just
# that file, verified against the x86 manifest.
if [[ ! -f "$dir/steamcmd.sh" ]]; then
  curl -fsSL "$mirror/steam_cmd_linux" -o steam_cmd_linux.manifest
  read -r file sha < <(awk -F'"' '
    $2!="" && $4=="" {block=$2}
    block=="steamcmd_linux" && $2=="file" {f=$4}
    block=="steamcmd_linux" && $2=="sha2" {print f, $4; exit}' steam_cmd_linux.manifest)
  echo "fetch $file (for steamcmd.sh)"
  curl -fsSL "$mirror/$file" -o "$file"
  echo "$sha  $file" | sha256sum -c --quiet
  unzip -qo "$file" steamcmd.sh -d "$dir"
  rm -f "$file" steam_cmd_linux.manifest
fi
chmod 755 "$dir/steamcmd.sh"
for f in "$dir"/linux*/steamcmd "$dir"/linux*/steamerrorreporter; do
  if [[ -f "$f" ]]; then chmod 755 "$f"; fi
done
echo "seeded steamcmd ($manifest) $(awk -F'"' '$2=="version"{print $4; exit}' "$manifest.manifest")"
