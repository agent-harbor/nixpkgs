#!/usr/bin/env bash
# smoke.sh <attr> <installed-prefix> <system>
#
# Use a built package the way a user would, beyond the package's own checks.
# <installed-prefix> is a store path or a Nix profile (anything with bin/).
# A package without a case here only gets the generic check.
set -euo pipefail

attr=$1 prefix=$2 system=$3
version=${VERSION:?VERSION is the package version}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

main=$(nix eval --raw --impure --file "${WORK:?}" "$attr.meta.mainProgram" 2>/dev/null || true)
if [[ -n "$main" ]]; then
  test -x "$prefix/bin/$main" || { echo "::error::$attr: $prefix/bin/$main is missing"; exit 1; }
fi

case "$attr" in
  agent-harbor)
    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # The wrapper execs the prebuilt release binary. On macOS this also loads
    # the vendored dylibs through @loader_path, so a broken layout fails here.
    got=$("$prefix/bin/ah" --version 2>&1) || { echo "::error::ah --version failed: $got"; exit 1; }
    echo "ah --version: $got"
    grep -qF "$version" <<<"$got" || { echo "::error::expected ah --version to report $version"; exit 1; }

    # The package's own store path (the profile only links to it).
    root=$(dirname "$(dirname "$(readlink -f "$prefix/bin/ah")")")
    runtime="$root/libexec/agent-harbor/runtime-bin"
    # package.nix wires in the Claude Code ACP adapter only when the package
    # set has one (`claude-code-acp`, renamed `claude-agent-acp`); nixos-25.05
    # has neither, so there it cannot be required. Where the set has one, ah
    # must find it. If this evaluation fails, require it.
    has_acp=$(nix eval --impure --raw --expr "
      let p = import ${WORK} { system = \"$system\"; };
      in if p ? claude-agent-acp || p ? claude-code-acp then \"yes\" else \"no\"" 2>/dev/null || echo yes)
    if [[ "$has_acp" == yes ]]; then
      test -x "$runtime/claude-code-acp" ||
        { echo "::error::$runtime/claude-code-acp is missing: ah cannot start Claude Code sessions"; exit 1; }
    else
      echo "::notice::this package set has no Claude Code ACP adapter; ah is built without one"
    fi

    if [[ "$system" == *-linux ]]; then
      test -x "$runtime/slirp4netns" ||
        { echo "::error::$runtime/slirp4netns is missing: ah's sandbox has no network egress"; exit 1; }
      # services.agent-harbor starts the daemon only if it offers both
      # allowlist flags (nixos/modules/services/misc/agent-harbor.nix).
      help=$("$prefix/bin/ah-fs-snapshots-daemon" --help 2>&1) ||
        { echo "::error::ah-fs-snapshots-daemon --help failed: $help"; exit 1; }
      for flag in --allowed-zfs-dataset --allowed-btrfs-path; do
        grep -qF -- "$flag" <<<"$help" ||
          { echo "::error::ah-fs-snapshots-daemon --help does not offer $flag"; exit 1; }
      done
    fi
    ;;
esac
echo "smoke ok: $attr $version on $system"
