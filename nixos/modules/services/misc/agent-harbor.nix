{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agent-harbor;
  socketPath = "/run/agent-harbor/ah-fs-snapshots-daemon.sock";
  activationStore = cfg.activationStore;
  gcRootsDir = cfg.gcRootsDir;
  daemonGcRoot = "${gcRootsDir}/daemon-${builtins.baseNameOf "${cfg.package}"}";
in
{
  meta.maintainers = [ ];

  options.services.agent-harbor = {
    enable = lib.mkEnableOption "Agent Harbor filesystem snapshots daemon";

    package = lib.mkPackageOption pkgs "agent-harbor" { };

    activationStore = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-harbor/activation-store";
      description = "Filesystem path for Agent Harbor installed-version activation metadata.";
    };

    gcRootsDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-harbor/nix-gcroots";
      description = "Directory where the NixOS module creates indirect GC-root symlinks for live Agent Harbor runtime roots.";
    };

    nixStoreBin = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.nix}/bin/nix-store";
      defaultText = lib.literalExpression ''"''${pkgs.nix}/bin/nix-store"'';
      description = "nix-store executable used to register indirect GC roots for live Agent Harbor package roots.";
    };

    snapshotDaemon = {
      readWritePaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/var/lib/agent-harbor"
          "/run/agent-harbor"
        ];
        description = "Paths the snapshot daemon is allowed to write to (for mount points and runtime state).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Ensure ReadWritePaths directories exist so ProtectSystem=strict
    # mount namespacing does not fail at service start.
    systemd.tmpfiles.rules = map (p: "d ${p} 0755 root root -") (
      cfg.snapshotDaemon.readWritePaths
      ++ [
        activationStore
        gcRootsDir
      ]
    );

    system.activationScripts.agentHarborActivateInstalledVersion.text = ''
      mkdir -p ${lib.escapeShellArg activationStore} ${lib.escapeShellArg gcRootsDir}
      rm -f ${lib.escapeShellArg daemonGcRoot}
      ${lib.escapeShellArg cfg.nixStoreBin} --add-root ${lib.escapeShellArg daemonGcRoot} --indirect --realise ${lib.escapeShellArg "${cfg.package}"}
      export AH_ACTIVATION_STORE=${lib.escapeShellArg activationStore}
      export AH_RUNTIME_ROOT=${lib.escapeShellArg "${cfg.package}"}
      export AH_RUNTIME_ROOT_CHANNEL=nix
      export AH_RUNTIME_GC_ROOT=${lib.escapeShellArg daemonGcRoot}
      export AH_NIX_GC_ROOTS_DIR=${lib.escapeShellArg gcRootsDir}
      export AH_NIX_STORE_BIN=${lib.escapeShellArg cfg.nixStoreBin}
      export AH_BIN=${lib.escapeShellArg "${cfg.package}/bin/ah"}
      ${lib.escapeShellArg "${cfg.package}/bin/ah"} daemon activate-installed-version \
        --installed-version-dir ${lib.escapeShellArg "${cfg.package}"} \
        --storage-mode external-immutable \
        --runtime-channel nix \
        --activation-store ${lib.escapeShellArg activationStore} \
        --runtime-pin ${lib.escapeShellArg daemonGcRoot}
    '';

    # Socket unit — systemd listens on the Unix socket and starts the
    # daemon on first client connection.
    systemd.sockets.ah-fs-snapshots-daemon = {
      description = "Agent Harbor Filesystem Snapshots Daemon Socket";
      wantedBy = [ "sockets.target" ];

      socketConfig = {
        ListenStream = socketPath;
        SocketMode = "0666";
        DirectoryMode = "0755";
        RemoveOnStop = true;
      };
    };

    # The snapshot daemon needs root for CAP_SYS_ADMIN (mount operations on
    # ZFS/Btrfs snapshots). It communicates with the unprivileged `ah` CLI
    # over a Unix socket passed by systemd.
    systemd.services.ah-fs-snapshots-daemon = {
      description = "Agent Harbor Filesystem Snapshots Daemon";
      restartIfChanged = false;
      after = [
        "network.target"
        "local-fs.target"
      ];
      wants = [ "zfs.target" ];
      requires = [ "ah-fs-snapshots-daemon.socket" ];

      serviceConfig = {
        Type = "notify";
        ExecStart = "${cfg.package}/bin/ah-fs-snapshots-daemon --socket-path ${socketPath}";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;

        # Security hardening
        NoNewPrivileges = false; # needs CAP_SYS_ADMIN for mounts
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        ReadWritePaths = cfg.snapshotDaemon.readWritePaths;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_LOCAL"
        ];
      };
    };

    # FUSE allow_other so the agent can access mounted snapshots
    programs.fuse.userAllowOther = lib.mkDefault true;
  };
}
