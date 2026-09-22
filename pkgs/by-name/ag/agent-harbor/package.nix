{
  lib,
  stdenv,
  fetchurl,
  nix,
}:

let
  inherit (stdenv.hostPlatform) system;

  # Pre-built binaries from the Agent Harbor release pipeline: musl-static on
  # linux, and a vendored-dylib bundle on macOS. Neither needs patching, so
  # there is no autoPatchelfHook and `dontFixup` is set below — on darwin that
  # is load-bearing, because the bundle's install names are already correct
  # relative to each other and rewriting them would break the `@loader_path`
  # chain described in `installPhase`.
  version = "0.6.0";

  # `sourceRoot` is per-platform and NOT derivable from `system`: the linux
  # tarball unpacks to `agent-harbor-portable-<system>/`, the macOS one to
  # `ah-macos-arm64/`. Keeping it next to the url it belongs to is what stops
  # a new platform from silently unpacking into the wrong directory.
  sources = {
    x86_64-linux = {
      url = "https://downloads.agent-harbor.com/linux/v${version}/agent-harbor-portable-${version}-x86_64-linux.tar.gz";
      hash = "sha256-pJYa2Dw7WiWcDz/y9nXmMFAbFQUnbqFfTnLObkhbVks="; # x86_64
      sourceRoot = "agent-harbor-portable-x86_64-linux";
    };
    aarch64-darwin = {
      # Mirrors the release asset `ah-macos-arm64.tar.gz` under the `macos/`
      # prefix, matching how the linux tarball is published: the R2 uploader
      # (`scripts/upload-linux-portable-cloudflare.sh`) writes
      # `<prefix>/v<version>/<original filename>`, and `install.sh` already
      # uses `downloads.agent-harbor.com/macos` as the macOS prefix.
      url = "https://downloads.agent-harbor.com/macos/v${version}/ah-macos-arm64.tar.gz";
      hash = "sha256-XLoamQbQqK6GLLVWXa6jPjpKwKYTNlVtpEKSf6C5kCk="; # aarch64-darwin
      sourceRoot = "ah-macos-arm64";
    };
    # aarch64-linux: not yet published; add here when available
  };

  source = sources.${system} or (throw "agent-harbor: unsupported platform ${system}");
in

stdenv.mkDerivation {
  pname = "agent-harbor";
  inherit version;

  src = fetchurl { inherit (source) url hash; };

  inherit (source) sourceRoot;

  # Prebuilt release binaries — nothing to patch or strip
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec/agent-harbor

    # The two tarballs do NOT share an internal layout. The linux portable
    # tarball nests its executables under `bin/`; the macOS bundle puts `ah`
    # and `ah-fs-snapshots-daemon` at its root, with no `bin/` at all.
    # Normalise to one variable rather than branching over every copy below.
    binDir=bin
    [ -d bin ] || binDir=.

    # Fail loudly on an unrecognised layout. Without this the copies below are
    # simply skipped, the derivation SUCCEEDS with an empty libexec, and the
    # wrapper written at the end points at a file that does not exist — so the
    # first symptom is `ah: No such file or directory` on a user's machine
    # rather than a build error.
    if [ ! -f "$binDir/ah" ]; then
      echo "agent-harbor: no 'ah' executable under '$binDir/' in ${source.sourceRoot}." >&2
      echo "  The release changed its tarball layout; installPhase needs a case for it." >&2
      echo "  Found instead:" >&2
      ls -A >&2
      exit 1
    fi
    install -m 0755 "$binDir/ah" "$out/libexec/agent-harbor/ah"

    for bin in ah-fs-snapshots-daemon agentharborfs-fuse agentharborfs-daemon agentfs-fuse; do
      if [ -f "$binDir/$bin" ]; then
        install -m 0755 "$binDir/$bin" "$out/bin/$bin"
      fi
    done

    if [ -d "lib" ]; then
      mkdir -p "$out/lib"
      cp -a lib/. "$out/lib/"
      # On macOS `ah` carries LC_RPATH=@loader_path/lib and loads
      # @rpath/libonnxruntime.<v>.dylib through it, so the libraries must be
      # reachable as a SIBLING of the real binary. The real binary lives in
      # libexec (only the wrapper is in bin), so the link has to be there.
      # Inert on linux, where the binaries are static; required on darwin.
      ln -s "$out/lib" "$out/libexec/agent-harbor/lib"
    fi

    if [ -d "share" ]; then
      mkdir -p "$out/share"
      cp -a share/. "$out/share/"
    fi

    cat > "$out/bin/ah" <<EOF
    #!${stdenv.shell}
    set -u

    export AH_RUNTIME_ROOT="\''${AH_RUNTIME_ROOT:-$out}"
    export AH_RUNTIME_ROOT_CHANNEL="\''${AH_RUNTIME_ROOT_CHANNEL:-nix}"
    export AH_BIN="\''${AH_BIN:-$out/bin/ah}"
    export AH_NIX_STORE_BIN="\''${AH_NIX_STORE_BIN:-${nix}/bin/nix-store}"

    if [ "\''${AH_ACTIVATION_STORE:-}" != "" ] && [ "\''${AH_RUNTIME_GC_ROOT:-}" = "" ] && [ "\''${1:-}" = "agent" ] && [ "\''${2:-}" = "record" ]; then
      gc_roots_dir="\''${AH_NIX_GC_ROOTS_DIR:-\''${XDG_STATE_HOME:-\''${HOME:-/tmp}/.local/state}/agent-harbor/nix-gcroots}"
      if mkdir -p "\$gc_roots_dir"; then
        runtime_name="\$(basename "\$AH_RUNTIME_ROOT")"
        candidate_gc_root="\$gc_roots_dir/runner-\$runtime_name-\$\$"
        rm -f "\$candidate_gc_root"
        if "\$AH_NIX_STORE_BIN" --add-root "\$candidate_gc_root" --indirect --realise "\$AH_RUNTIME_ROOT" >/dev/null 2>&1; then
          export AH_RUNTIME_GC_ROOT="\$candidate_gc_root"
        else
          rm -f "\$candidate_gc_root"
        fi
      fi
    fi

    exec "$out/libexec/agent-harbor/ah" "\$@"
    EOF
    chmod +x "$out/bin/ah"

    runHook postInstall
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "AI coding agent orchestration platform";
    homepage = "https://agent-harbor.com";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "ah";
    platforms = builtins.attrNames sources;
  };
}
