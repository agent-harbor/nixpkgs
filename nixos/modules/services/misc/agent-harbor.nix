{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agent-harbor;
  socketPath = "/run/agent-harbor/ah-fs-snapshots-daemon.sock";
in
{
  meta.maintainers = [ ];

  options.services.agent-harbor = {
    enable = lib.mkEnableOption "Agent Harbor filesystem snapshots daemon";

    package = lib.mkPackageOption pkgs "agent-harbor" { };

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
    systemd.tmpfiles.rules =
      map (p: "d ${p} 0755 root root -") cfg.snapshotDaemon.readWritePaths;

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
