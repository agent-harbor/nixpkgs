{
  lib,
  stdenv,
  fetchurl,
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

  src = fetchurl (
    sources.${system} or (throw "agent-harbor: unsupported platform ${system}")
  );

  # Musl-static binaries — nothing to patch or strip
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  sourceRoot = "agent-harbor-portable-${
    {
      x86_64-linux = "x86_64-linux";
      aarch64-linux = "aarch64-linux";
    }.${system}
  }";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    for bin in ah ah-fs-snapshots-daemon agentfs-fuse; do
      if [ -f "bin/$bin" ]; then
        install -m 0755 "bin/$bin" "$out/bin/$bin"
      fi
    done

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
