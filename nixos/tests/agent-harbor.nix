{
  lib,
  pkgs,
  ...
}:

let
  socketPath = "/run/agentharborfsd/ah-fs-snapshots-daemon";
  runtimeDir = "/run/agentharborfsd";
  difficultBtrfsPath = "/srv/agent harbor/%n/$NOT_EXPANDED;\"quoted\"";
  explicitReadWritePath = "/srv/agent-harbor-existing-writable";

  fakeAh = pkgs.writeShellScriptBin "ah" ''
    exit 0
  '';

  fakeSnapshotDaemon = pkgs.writeShellScriptBin "ah-fs-snapshots-daemon" ''
    set -eu

    if [ "''${1:-}" = "--help" ]; then
      printf '%s\n' \
        'Usage: ah-fs-snapshots-daemon [OPTIONS]' \
        '  --allowed-zfs-dataset <DATASET>' \
        '  --allowed-btrfs-path <PATH>'
      exit 0
    fi

    printf '%s\0' "$@" > /run/agentharborfsd/daemon-args

    for executable in zfs btrfs mount stat; do
      resolved="$(command -v "$executable")"
      printf '%s=%s\n' "$executable" "$resolved"
    done > /run/agentharborfsd/runtime-tools

    ${pkgs.coreutils}/bin/touch /tmp/ah-zfs-clones/service-visible
    ${pkgs.coreutils}/bin/touch ${lib.escapeShellArg "${difficultBtrfsPath}/service-visible"}

    # What the real daemon does for every cow-overlay workspace: mount a clone
    # or snapshot for the requesting user. Those mounts must be visible on the
    # host, i.e. the service must not run in a private mount namespace.
    for root in /tmp/ah-zfs-clones ${lib.escapeShellArg difficultBtrfsPath}; do
      ${pkgs.coreutils}/bin/mkdir -p "$root/mount-probe"
      ${pkgs.util-linux}/bin/mount -t tmpfs ah-mount-probe "$root/mount-probe"
      ${pkgs.coreutils}/bin/touch "$root/mount-probe/inside"
    done

    ${pkgs.systemd}/bin/systemd-notify --pid=parent --ready
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';

  fakeIncompatibleSnapshotDaemon = pkgs.writeShellScriptBin "ah-fs-snapshots-daemon" ''
    set -eu

    if [ "''${1:-}" = "--help" ]; then
      printf '%s\n' 'Usage: ah-fs-snapshots-daemon [OPTIONS]'
      exit 0
    fi

    ${pkgs.coreutils}/bin/touch /run/agentharborfsd/incompatible-daemon-started
    exit 1
  '';

  mkVersionlessTestPackage =
    name: snapshotDaemon:
    pkgs.runCommand name { } ''
      mkdir -p "$out/bin"
      ln -s ${fakeAh}/bin/ah "$out/bin/ah"
      ln -s ${snapshotDaemon}/bin/ah-fs-snapshots-daemon "$out/bin/ah-fs-snapshots-daemon"
    '';

  testPackage = mkVersionlessTestPackage "agent-harbor-test-package" fakeSnapshotDaemon;
  incompatibleTestPackage = mkVersionlessTestPackage "agent-harbor-incompatible-test-package" fakeIncompatibleSnapshotDaemon;

  # Keep negative module evaluations independent of the test driver's `pkgs`
  # fixpoint; feeding that package set back through eval-config recurses.
  evalPkgs = import ../.. {
    system = builtins.currentSystem;
    config.allowUnfree = true;
  };
  evalVersionlessPackage = evalPkgs.runCommand "agent-harbor-eval-versionless-package" { } ''
    mkdir -p "$out/bin"
  '';
  evalStorePathPackage = builtins.storePath (builtins.toFile "agent-harbor-eval-store-path" "");
  evalCompatibleVersionedPackage = evalVersionlessPackage // {
    version = "0.5.0";
  };
  # Releases before 0.4.0 have no filesystem allowlists and must be refused,
  # the default package of this branch (0.3.19) included.
  evalIncompatibleVersionedPackage = evalVersionlessPackage // {
    version = "0.3.19";
  };
  baseServiceConfig = {
    enable = true;
    package = evalVersionlessPackage;
    snapshotDaemon = {
      accessGroup = "ah-snapshot-access";
      allowedZfsDatasets = [ "tank/valid" ];
      allowedBtrfsPaths = [ "/srv/valid" ];
    };
  };

  evalConfiguration =
    overrides:
    import ../lib/eval-config.nix {
      system = null;
      modules = [
        {
          nixpkgs.pkgs = evalPkgs;
          system.stateVersion = "25.05";
          fileSystems."/" = {
            device = "/dev/vda";
            fsType = "ext4";
          };
          boot.loader.grub.device = "/dev/vda";
          services.agent-harbor = lib.recursiveUpdate baseServiceConfig overrides;
        }
      ];
    };

  evaluationSucceeds =
    overrides:
    (builtins.tryEval (
      builtins.deepSeq (evalConfiguration overrides).config.system.build.toplevel.drvPath true
    )).success;
in
assert !(evalVersionlessPackage ? version);
assert evaluationSucceeds { };
assert evaluationSucceeds { package = evalStorePathPackage; };
assert evaluationSucceeds { package = evalCompatibleVersionedPackage; };
assert !evaluationSucceeds { package = evalPkgs.agent-harbor; };
assert !evaluationSucceeds { package = evalIncompatibleVersionedPackage; };
assert !evaluationSucceeds { snapshotDaemon.accessGroup = "root"; };
assert !evaluationSucceeds { snapshotDaemon.allowedZfsDatasets = [ "tank/valid@snapshot" ]; };
assert !evaluationSucceeds { snapshotDaemon.allowedZfsDatasets = [ "tank/../escaped" ]; };
assert !evaluationSucceeds { snapshotDaemon.allowedBtrfsPaths = [ "relative/path" ]; };
assert !evaluationSucceeds { snapshotDaemon.allowedBtrfsPaths = [ "/srv/allowed/../escaped" ]; };
assert !evaluationSucceeds { snapshotDaemon.allowedBtrfsPaths = [ "/" ]; };
assert !evaluationSucceeds { snapshotDaemon.readWritePaths = [ "/" ]; };
assert !evaluationSucceeds { activationStore = "relative/path"; };
assert !evaluationSucceeds { gcRootsDir = "/var/lib/../escaped"; };
{
  name = "agent-harbor";

  nodes = {
    machine = {
      services.agent-harbor = {
        enable = true;
        package = testPackage;
        snapshotDaemon = {
          accessGroup = "ah-snapshot-access";
          allowedUsers = [
            "alice"
            "alice"
          ];
          allowedZfsDatasets = [
            "tank/agent-harbor"
            "tank/secondary"
            "tank/agent-harbor"
          ];
          allowedBtrfsPaths = [
            difficultBtrfsPath
            difficultBtrfsPath
          ];
          # The module must retain its hard-coded daemon staging root even when
          # an operator replaces the additional writable paths.
          readWritePaths = [
            "/var/lib/agent-harbor"
            explicitReadWritePath
          ];
        };
      };

      # These paths represent operator-managed mount roots. The module may
      # create them when absent, but must preserve metadata when they exist.
      system.activationScripts.prepareAgentHarborOperatorPaths = {
        deps = [ "users" ];
        text = ''
          install -d -m 0710 -o alice -g users ${lib.escapeShellArg difficultBtrfsPath}
          install -d -m 0730 -o carol -g users ${lib.escapeShellArg explicitReadWritePath}
        '';
      };

      users.users = {
        alice.isNormalUser = true;
        bob.isNormalUser = true;
        carol.isNormalUser = true;
      };
      users.groups.ah-snapshot-access.members = [ "carol" ];
    };

    deny = {
      services.agent-harbor = {
        enable = true;
        package = testPackage;
        snapshotDaemon = {
          accessGroup = "ah-deny-access";
          readWritePaths = [ difficultBtrfsPath ];
        };
      };
    };

    incompatible = {
      services.agent-harbor = {
        enable = true;
        package = incompatibleTestPackage;
        snapshotDaemon.accessGroup = "ah-incompatible-access";
      };

      # Keep the failure terminal so the test can inspect the rejected start.
      systemd.services.ah-fs-snapshots-daemon.serviceConfig.Restart = lib.mkForce "no";
    };
  };

  testScript = ''
    import json
    import shlex

    socket_path = ${builtins.toJSON socketPath}
    runtime_dir = ${builtins.toJSON runtimeDir}
    difficult_path = ${builtins.toJSON difficultBtrfsPath}
    explicit_read_write_path = ${builtins.toJSON explicitReadWritePath}

    def connect_command(user):
        program = (
            "import socket; "
            f"sock = socket.socket(socket.AF_UNIX); sock.connect({socket_path!r}); sock.close()"
        )
        return (
            f"sudo -u {shlex.quote(user)} ${pkgs.python3}/bin/python3 -c "
            f"{shlex.quote(program)}"
        )

    def read_nul_args(node, path):
        program = (
            "import json; "
            f"raw = open({path!r}, 'rb').read(); "
            "assert raw.endswith(b'\\0'); "
            "print(json.dumps([part.decode() for part in raw[:-1].split(b'\\0')]))"
        )
        return json.loads(
            node.succeed(
                f"${pkgs.python3}/bin/python3 -c {shlex.quote(program)}"
            )
        )

    machine.start()

    with subtest("dedicated access group merges explicit trusted members"):
        machine.succeed("getent group ah-snapshot-access")
        alice_groups = machine.succeed("id -nG alice").split()
        bob_groups = machine.succeed("id -nG bob").split()
        carol_groups = machine.succeed("id -nG carol").split()
        assert "ah-snapshot-access" in alice_groups, alice_groups
        assert "ah-snapshot-access" in carol_groups, carol_groups
        assert "ah-snapshot-access" not in bob_groups, bob_groups

    with subtest("socket and parent directory deny untrusted clients"):
        machine.wait_for_unit("ah-fs-snapshots-daemon.socket")
        machine.wait_for_file(socket_path)

        runtime_metadata = machine.succeed(
            f"stat -c '%a %U %G' {shlex.quote(runtime_dir)}"
        ).strip()
        socket_metadata = machine.succeed(
            f"stat -c '%a %U %G' {shlex.quote(socket_path)}"
        ).strip()
        assert runtime_metadata == "750 root ah-snapshot-access", runtime_metadata
        assert socket_metadata == "660 root ah-snapshot-access", socket_metadata

        machine.fail(connect_command("bob"))
        machine.fail("systemctl is-active --quiet ah-fs-snapshots-daemon.service")
        machine.succeed(connect_command("alice"))
        machine.wait_for_unit("ah-fs-snapshots-daemon.service")

    with subtest("generated unit shares the host mount namespace and keeps literal specifiers"):
        unit = machine.succeed("systemctl cat ah-fs-snapshots-daemon.service")
        for directive in ("ProtectSystem=", "ProtectHome=", "ReadWritePaths=", "BindPaths="):
            assert directive not in unit, (directive, unit)
        assert "PrivateTmp=false" in unit, unit
        assert "PrivateMounts=false" in unit, unit
        # systemd's own escaping ($ -> $$, % -> %%); the exact unescaped value
        # the daemon receives is asserted in the allowlist-arguments subtest.
        assert "/srv/agent harbor/%%n/$$NOT_EXPANDED" in unit, unit
        assert "--unrestricted" not in unit, unit

        machine.succeed(f"test -d {shlex.quote(difficult_path)}")
        private_tmp = machine.succeed(
            "systemctl show --property=PrivateTmp --value ah-fs-snapshots-daemon.service"
        ).strip()
        assert private_tmp == "no", private_tmp

    with subtest("tmpfiles preserves operator-managed directory metadata"):
        btrfs_metadata = machine.succeed(
            f"stat -c '%a %U %G' {shlex.quote(difficult_path)}"
        ).strip()
        read_write_metadata = machine.succeed(
            f"stat -c '%a %U %G' {shlex.quote(explicit_read_write_path)}"
        ).strip()
        assert btrfs_metadata == "710 alice users", btrfs_metadata
        assert read_write_metadata == "730 carol users", read_write_metadata

    with subtest("daemon receives exact deduplicated allowlist arguments"):
        machine.wait_for_file("/run/agentharborfsd/daemon-args")
        args = read_nul_args(machine, "/run/agentharborfsd/daemon-args")
        assert args == [
            "--socket-path",
            socket_path,
            "--allowed-zfs-dataset",
            "tank/agent-harbor",
            "--allowed-zfs-dataset",
            "tank/secondary",
            "--allowed-btrfs-path",
            difficult_path,
        ], args
        assert "%n" in args[-1], args
        assert "$NOT_EXPANDED" in args[-1], args
        assert "--unrestricted" not in args, args

    with subtest("service PATH resolves filesystem runtime tools"):
        tools = machine.succeed("cat /run/agentharborfsd/runtime-tools").splitlines()
        assert tools == [
            "zfs=${pkgs.zfs}/bin/zfs",
            "btrfs=${pkgs.btrfs-progs}/bin/btrfs",
            "mount=${pkgs.util-linux}/bin/mount",
            "stat=${pkgs.coreutils}/bin/stat",
        ], tools

    with subtest("mounts made by the daemon are visible on the host"):
        staging_metadata = machine.succeed(
            "stat -c '%a %U %G' /tmp/ah-zfs-clones"
        ).strip()
        assert staging_metadata == "755 root root", staging_metadata
        machine.succeed("test -e /tmp/ah-zfs-clones/service-visible")
        machine.succeed(
            f"test -e {shlex.quote(difficult_path + '/service-visible')}"
        )
        for root in ("/tmp/ah-zfs-clones", difficult_path):
            probe = root + "/mount-probe"
            source = machine.succeed(
                f"findmnt -n -o SOURCE --mountpoint {shlex.quote(probe)}"
            ).strip()
            assert source == "ah-mount-probe", (probe, source)
            machine.succeed(f"test -e {shlex.quote(probe + '/inside')}")

    deny.start()

    with subtest("empty allowlists generate explicit deny-all arguments"):
        deny.wait_for_unit("ah-fs-snapshots-daemon.socket")
        deny.succeed("systemctl start ah-fs-snapshots-daemon.service")
        deny.wait_for_unit("ah-fs-snapshots-daemon.service")
        deny.wait_for_file("/run/agentharborfsd/daemon-args")
        args = read_nul_args(deny, "/run/agentharborfsd/daemon-args")
        assert args == [
            "--socket-path",
            socket_path,
            "--allowed-zfs-dataset",
            "/",
            "--allowed-btrfs-path",
            "/dev/null",
        ], args
        assert "--unrestricted" not in args, args

    incompatible.start()

    with subtest("pre-start capability probe rejects a versionless incompatible daemon"):
        incompatible.wait_for_unit("ah-fs-snapshots-daemon.socket")
        incompatible.fail("systemctl start ah-fs-snapshots-daemon.service")
        incompatible.fail("systemctl is-active --quiet ah-fs-snapshots-daemon.service")
        incompatible.fail("test -e /run/agentharborfsd/incompatible-daemon-started")
        pre_start_status = incompatible.succeed(
            "systemctl show --property=ExecStartPre --value ah-fs-snapshots-daemon.service"
        )
        assert "code=exited" in pre_start_status, pre_start_status
        assert "status=1" in pre_start_status, pre_start_status
  '';
}
