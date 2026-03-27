#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl gnused gawk nix-prefetch

set -euo pipefail

ROOT="$(dirname "$(readlink -f "$0")")"
PKG_NIX="$ROOT/package.nix"

# Get the latest release version from GitHub
LATEST_VER=$(curl -Ls -w "%{url_effective}" -o /dev/null \
  https://github.com/blocksense-network/agent-harbor/releases/latest \
  | awk -F'/' '{print $NF}' | sed 's/^v//')

echo "Latest version: $LATEST_VER"

CURRENT_VER=$(grep 'version = ' "$PKG_NIX" | head -1 | sed 's/.*"\(.*\)".*/\1/')
echo "Current version: $CURRENT_VER"

if [[ "$LATEST_VER" == "$CURRENT_VER" ]]; then
  echo "Already up to date."
  exit 0
fi

# Prefetch x86_64-linux tarball
echo "Fetching x86_64-linux hash..."
X86_64_HASH=$(nix-prefetch "{ stdenv, fetchurl }:
stdenv.mkDerivation {
  pname = \"agent-harbor\"; version = \"${LATEST_VER}\";
  src = fetchurl {
    url = \"https://downloads.agent-harbor.com/linux/v${LATEST_VER}/agent-harbor-portable-${LATEST_VER}-x86_64-linux.tar.gz\";
  };
}
")
echo "x86_64-linux hash: $X86_64_HASH"

# Update version
sed -i "s/version = \".*\"/version = \"$LATEST_VER\"/" "$PKG_NIX"

# Update x86_64-linux hash
sed -i "s|hash = \"sha256-.\{44\}\"; # x86_64|hash = \"$X86_64_HASH\"; # x86_64|" "$PKG_NIX"

# If aarch64-linux source exists, try to prefetch it too
if grep -q 'aarch64-linux' "$PKG_NIX" && ! grep -q '# aarch64-linux: not yet' "$PKG_NIX"; then
  echo "Fetching aarch64-linux hash..."
  AARCH64_HASH=$(nix-prefetch "{ stdenv, fetchurl }:
  stdenv.mkDerivation {
    pname = \"agent-harbor\"; version = \"${LATEST_VER}\";
    src = fetchurl {
      url = \"https://downloads.agent-harbor.com/linux/v${LATEST_VER}/agent-harbor-portable-${LATEST_VER}-aarch64-linux.tar.gz\";
    };
  }
  " 2>/dev/null) || true

  if [[ -n "$AARCH64_HASH" ]]; then
    echo "aarch64-linux hash: $AARCH64_HASH"
    sed -i "s|hash = \"sha256-.\{44\}\"; # aarch64|hash = \"$AARCH64_HASH\"; # aarch64|" "$PKG_NIX"
  else
    echo "aarch64-linux tarball not found, skipping."
  fi
fi

echo "Updated agent-harbor: $CURRENT_VER -> $LATEST_VER"
