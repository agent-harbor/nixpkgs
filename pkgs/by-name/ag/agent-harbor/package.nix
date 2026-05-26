{
  lib,
  stdenv,
  fetchurl,
  nix,
}:

let
  inherit (stdenv.hostPlatform) system;

  # Pre-built musl-static binaries from the Agent Harbor release pipeline.
  # No autoPatchelfHook needed — binaries are fully statically linked.
  version = "0.3.19";

  sources = {
    x86_64-linux = {
      url = "https://downloads.agent-harbor.com/linux/v${version}/agent-harbor-portable-${version}-x86_64-linux.tar.gz";
      hash = "sha256-BDDptvz5Z1wQZoXp/shp3VzQF8OMILk/gJO4W7CS87M="; # x86_64
    };
    # aarch64-linux: not yet published; add here when available
  };
in

stdenv.mkDerivation {
  pname = "agent-harbor";
  inherit version;

  src = fetchurl (sources.${system} or (throw "agent-harbor: unsupported platform ${system}"));

  # Musl-static binaries — nothing to patch or strip
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  sourceRoot = "agent-harbor-portable-${
    {
      x86_64-linux = "x86_64-linux";
      aarch64-linux = "aarch64-linux";
    }
    .${system}
  }";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec/agent-harbor

    if [ -f "bin/ah" ]; then
      install -m 0755 "bin/ah" "$out/libexec/agent-harbor/ah"
    fi

    for bin in ah-fs-snapshots-daemon agentfs-fuse; do
      if [ -f "bin/$bin" ]; then
        install -m 0755 "bin/$bin" "$out/bin/$bin"
      fi
    done

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
