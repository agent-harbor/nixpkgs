#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl gnused gawk nix-prefetch gh

set -euo pipefail

ROOT="$(dirname "$(readlink -f "$0")")"
PKG_NIX="$ROOT/package.nix"

REPO="${AGENT_HARBOR_REPO:-agent-harbor/agent-harbor}"

# Resolve the latest release version.
#
# The previous probe followed github.com/<repo>/releases/latest and took the
# last path segment. That repository is PRIVATE, so an unauthenticated request
# is NOT redirected to the tag — the segment comes back as the literal string
# "latest", which the script then wrote into package.nix as
# `version = "latest"`, producing a package pointing at a URL that does not
# exist. Ask the API first (it honours the maintainer's gh credential), keep
# the redirect probe as a fallback for a public mirror, and refuse to continue
# with anything that is not a version number.
LATEST_VER="${LATEST_VER:-}"
if [[ -z "$LATEST_VER" ]] && command -v gh >/dev/null 2>&1; then
  LATEST_VER=$(gh api "repos/${REPO}/releases/latest" --jq .tag_name 2>/dev/null | sed 's/^v//') || true
fi
if [[ -z "$LATEST_VER" ]]; then
  LATEST_VER=$(curl -Ls -w "%{url_effective}" -o /dev/null \
    "https://github.com/${REPO}/releases/latest" \
    | awk -F'/' '{print $NF}' | sed 's/^v//')
fi
if [[ ! "$LATEST_VER" =~ ^[0-9]+\.[0-9]+ ]]; then
  echo "error: could not resolve the latest agent-harbor version (got '${LATEST_VER}')." >&2
  echo "  ${REPO} is private, so the unauthenticated redirect probe returns 'latest'." >&2
  echo "  Run 'gh auth login', or pass the version explicitly: LATEST_VER=x.y.z $0" >&2
  exit 1
fi

echo "Latest version: $LATEST_VER"

CURRENT_VER=$(grep 'version = ' "$PKG_NIX" | head -1 | sed 's/.*"\(.*\)".*/\1/')
echo "Current version: $CURRENT_VER"

if [[ "$LATEST_VER" == "$CURRENT_VER" ]]; then
  echo "Already up to date."
  exit 0
fi

# Prefetch EVERY platform before editing anything.
#
# The package carries x86_64-linux and aarch64-darwin. Bumping the version
# while refreshing only one of the hashes leaves the other pointing at the new
# version's URL with the old version's hash, so that platform fails with a hash
# mismatch that reads like corruption rather than like a half-finished update.
# Prefetching first means a missing artifact aborts before package.nix is
# touched, leaving the working tree clean.
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

echo "Fetching aarch64-darwin hash..."
DARWIN_HASH=$(nix-prefetch "{ stdenv, fetchurl }:
stdenv.mkDerivation {
  pname = \"agent-harbor\"; version = \"${LATEST_VER}\";
  src = fetchurl {
    url = \"https://downloads.agent-harbor.com/macos/v${LATEST_VER}/ah-macos-arm64.tar.gz\";
  };
}
") || {
  echo "error: the macOS tarball for v${LATEST_VER} is not on downloads.agent-harbor.com." >&2
  echo "  Expected: https://downloads.agent-harbor.com/macos/v${LATEST_VER}/ah-macos-arm64.tar.gz" >&2
  echo "  The release publishes ah-macos-arm64.tar.gz as a GitHub asset, but the R2" >&2
  echo "  upload step (scripts/upload-linux-portable-cloudflare.sh) is Linux-scoped," >&2
  echo "  so the macOS tarball is never mirrored. Mirror it, then re-run." >&2
  echo "  package.nix was NOT modified." >&2
  exit 1
}
echo "aarch64-darwin hash: $DARWIN_HASH"

# Update version
sed -i "s/version = \".*\"/version = \"$LATEST_VER\"/" "$PKG_NIX"

# Update per-platform hashes. The trailing comments are the anchors — keep them
# in package.nix when adding a platform, or its hash will silently not update.
sed -i "s|hash = \"sha256-.\{44\}\"; # x86_64|hash = \"$X86_64_HASH\"; # x86_64|" "$PKG_NIX"
sed -i "s|hash = \"sha256-.\{44\}\"; # aarch64-darwin|hash = \"$DARWIN_HASH\"; # aarch64-darwin|" "$PKG_NIX"

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
    sed -i "s|hash = \"sha256-.\{44\}\"; # aarch64-linux|hash = \"$AARCH64_HASH\"; # aarch64-linux|" "$PKG_NIX"
  else
    echo "aarch64-linux tarball not found, skipping."
  fi
fi

echo "Updated agent-harbor: $CURRENT_VER -> $LATEST_VER"
