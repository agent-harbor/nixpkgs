{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.services.agent-harbor;
  socketPath = "/run/agent-harbor/ah-fs-snapshots-daemon.sock";
  runtimeDir = builtins.dirOf socketPath;
  zfsCloneRoot = "/tmp/ah-zfs-clones";
  denyAllZfsDataset = "/";
  denyAllBtrfsPath = "/dev/null";
  activationStore = cfg.activationStore;
  gcRootsDir = cfg.gcRootsDir;
  daemonGcRoot = "${gcRootsDir}/daemon-${builtins.baseNameOf "${cfg.package}"}";
  packageVersion = if cfg.package ? version then cfg.package.version else null;

  accountNameType = lib.types.addCheck lib.types.nonEmptyStr (
    name: builtins.match "[A-Za-z_][A-Za-z0-9_.-]{0,30}" name != null
  );
  isCanonicalAbsolutePath =
    path:
    lib.hasPrefix "/" path
    && (path == "/" || !lib.hasSuffix "/" path)
    && !lib.hasInfix "//" path
    && lib.all (segment: segment != "." && segment != "..") (lib.tail (lib.splitString "/" path));
  isConfinedPath = path: path != "/" && isCanonicalAbsolutePath path;
  isZfsDataset =
    dataset:
    builtins.match "[A-Za-z][A-Za-z0-9_.:-]*(/[A-Za-z0-9_.:-]+)*" dataset != null
    && lib.all (component: component != "." && component != "..") (lib.splitString "/" dataset);

  # Older compatible daemons may treat an omitted allowlist as unrestricted.
  # Pass values that cannot identify an operable ZFS dataset or Btrfs path when
  # the configured list is empty, so every supported version remains deny-all.
  effectiveAllowedZfsDatasets =
    if cfg.snapshotDaemon.allowedZfsDatasets == [ ] then
      [ denyAllZfsDataset ]
    else
      lib.unique cfg.snapshotDaemon.allowedZfsDatasets;
  effectiveAllowedBtrfsPaths =
    if cfg.snapshotDaemon.allowedBtrfsPaths == [ ] then
      [ denyAllBtrfsPath ]
    else
      lib.unique cfg.snapshotDaemon.allowedBtrfsPaths;

  daemonReadWritePaths = lib.unique (
    cfg.snapshotDaemon.readWritePaths
    ++ cfg.snapshotDaemon.allowedBtrfsPaths
    ++ [
      runtimeDir
      zfsCloneRoot
    ]
  );
  moduleManagedDirectories = lib.unique [
    activationStore
    gcRootsDir
    runtimeDir
    zfsCloneRoot
  ];
  operatorManagedDirectories = lib.filter (path: !lib.elem path moduleManagedDirectories) (
    lib.unique (cfg.snapshotDaemon.readWritePaths ++ cfg.snapshotDaemon.allowedBtrfsPaths)
  );
  otherModuleManagedDirectories = lib.filter (path: path != runtimeDir) moduleManagedDirectories;

  # toJSON provides systemd-compatible C quoting. Percent signs need separate
  # escaping because systemd expands specifiers even inside quoted values.
  escapeSystemdConfigArg = value: lib.replaceStrings [ "%" ] [ "%%" ] (builtins.toJSON value);
  tmpfilesDirectoryRule =
    path: mode: user: group:
    "d ${escapeSystemdConfigArg path} ${mode} ${escapeSystemdConfigArg user} ${escapeSystemdConfigArg group} -";
  daemonArgs = [
    "${cfg.package}/bin/ah-fs-snapshots-daemon"
    "--socket-path"
    socketPath
  ]
  ++ lib.concatMap (dataset: [
    "--allowed-zfs-dataset"
    dataset
  ]) effectiveAllowedZfsDatasets
  ++ lib.concatMap (path: [
    "--allowed-btrfs-path"
    path
  ]) effectiveAllowedBtrfsPaths;
in
{
  meta.maintainers = [ ];

  options.services.agent-harbor = {
    enable = lib.mkEnableOption "Agent Harbor filesystem snapshots daemon";

    package = lib.mkPackageOption pkgs "agent-harbor" {
      extraDescription = ''
        Packages with a declared version must be version 0.4.0 or newer because
        the snapshot daemon must support filesystem allowlists. Versionless
        derivations and store paths are accepted, and the service verifies the
        required allowlist flags before starting the daemon. Until the default
        package is updated, enabling this module requires overriding this option
        with a compatible package.
      '';
    };

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
      accessGroup = lib.mkOption {
        type = accountNameType;
        default = "agent-harbor";
        description = ''
          Group permitted to connect to the privileged snapshot daemon socket.
          Membership grants control over root-level filesystem snapshot operations
          and must be limited to trusted users.
        '';
      };

      allowedUsers = lib.mkOption {
        type = lib.types.listOf accountNameType;
        default = [ ];
        example = [ "alice" ];
        description = ''
          Users to add to the snapshot daemon access group. This is a convenience
          option; group membership can also be managed through
          {option}`users.groups`.
        '';
      };

      allowedZfsDatasets = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        example = [ "tank/agent-harbor" ];
        description = ''
          ZFS dataset prefixes on which the snapshot daemon may operate. Each
          value is passed as a separate `--allowed-zfs-dataset` argument. The
          empty default emits an explicit deny-all value; it never starts the
          daemon without a ZFS allowlist.
        '';
      };

      allowedBtrfsPaths = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        example = [ "/var/lib/agent-harbor/btrfs" ];
        description = ''
          Absolute Btrfs path prefixes on which the snapshot daemon may operate.
          Each value is passed as a separate `--allowed-btrfs-path` argument and
          added to the service's writable paths. Missing directories are created
          as root with mode 0755, while existing ownership and modes are
          preserved. The empty default emits an explicit deny-all value; it never
          starts the daemon without a Btrfs allowlist.
        '';
      };

      readWritePaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/var/lib/agent-harbor"
          "/run/agent-harbor"
          zfsCloneRoot
        ];
        defaultText = lib.literalExpression ''
          [
            "/var/lib/agent-harbor"
            "/run/agent-harbor"
            "/tmp/ah-zfs-clones"
          ]
        '';
        description = ''
          Paths the snapshot daemon is allowed to write to for mount points and
          runtime state. Missing directories are created as root with mode 0755,
          while existing ownership and modes are preserved. The module always
          adds its runtime directory and the current daemon's hard-coded
          `/tmp/ah-zfs-clones` client-visible ZFS clone root. The latter cannot be
          relocated until the daemon supports configuring its clone staging root.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          packageVersion == null
          || (builtins.isString packageVersion && lib.versionAtLeast packageVersion "0.4.0");
        message = "services.agent-harbor.package has a known version older than 0.4.0 and does not support filesystem allowlists";
      }
      {
        assertion =
          !lib.elem cfg.snapshotDaemon.accessGroup [
            "root"
            "users"
            "wheel"
          ];
        message = "services.agent-harbor.snapshotDaemon.accessGroup must be a dedicated group, not root, users, or wheel";
      }
      {
        assertion = lib.all isZfsDataset cfg.snapshotDaemon.allowedZfsDatasets;
        message = "services.agent-harbor.snapshotDaemon.allowedZfsDatasets must contain valid ZFS dataset names without snapshots";
      }
      {
        assertion = lib.all isConfinedPath cfg.snapshotDaemon.allowedBtrfsPaths;
        message = "services.agent-harbor.snapshotDaemon.allowedBtrfsPaths must contain canonical absolute paths other than /";
      }
      {
        assertion = lib.all isConfinedPath cfg.snapshotDaemon.readWritePaths;
        message = "services.agent-harbor.snapshotDaemon.readWritePaths must contain canonical absolute paths other than /";
      }
      {
        assertion = isConfinedPath activationStore;
        message = "services.agent-harbor.activationStore must be a canonical absolute path other than /";
      }
      {
        assertion = isConfinedPath gcRootsDir;
        message = "services.agent-harbor.gcRootsDir must be a canonical absolute path other than /";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    users.groups.${cfg.snapshotDaemon.accessGroup}.members = lib.mkAfter (
      lib.unique cfg.snapshotDaemon.allowedUsers
    );

    # Create operator-provided paths when absent, but never replace their
    # existing ownership or mode. Module-owned paths retain fixed metadata.
    systemd.tmpfiles.rules =
      map (path: tmpfilesDirectoryRule path ":0755" ":root" ":root") operatorManagedDirectories
      ++ map (path: tmpfilesDirectoryRule path "0755" "root" "root") otherModuleManagedDirectories
      ++ [ (tmpfilesDirectoryRule runtimeDir "0750" "root" cfg.snapshotDaemon.accessGroup) ];

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
        SocketUser = "root";
        SocketGroup = cfg.snapshotDaemon.accessGroup;
        SocketMode = "0660";
        DirectoryMode = "0750";
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
      path = [
        pkgs.zfs
        pkgs.btrfs-progs
        pkgs.util-linux
        pkgs.coreutils
      ];
      preStart = ''
        daemon_help="$(${cfg.package}/bin/ah-fs-snapshots-daemon --help)"
        ${pkgs.gnugrep}/bin/grep -Fq -- '--allowed-zfs-dataset' <<<"$daemon_help"
        ${pkgs.gnugrep}/bin/grep -Fq -- '--allowed-btrfs-path' <<<"$daemon_help"
      '';

      serviceConfig = {
        Type = "notify";
        User = "root";
        Group = "root";
        ExecStart = utils.escapeSystemdExecArgs daemonArgs;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;

        # Security hardening
        NoNewPrivileges = false; # needs CAP_SYS_ADMIN for mounts
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        # ZFS clone paths are returned to unprivileged clients. The daemon
        # currently hard-codes /tmp/ah-zfs-clones, so a private /tmp would make
        # successful clone mounts invisible to those clients. ProtectSystem and
        # ReadWritePaths keep the shared /tmp read-only outside the managed root.
        PrivateTmp = false;
        ReadWritePaths = map escapeSystemdConfigArg daemonReadWritePaths;
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
