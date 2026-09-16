{
  lib,
  pkgs,
  ...
}:

let
  socketPath = "/run/agent-harbor/ah-fs-snapshots-daemon.sock";
  difficultBtrfsPath = "/srv/agent harbor/%n/$NOT_EXPANDED;\"quoted\"";

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

    printf '%s\0' "$@" > /run/agent-harbor/daemon-args

    for executable in zfs btrfs mount stat; do
      resolved="$(command -v "$executable")"
      printf '%s=%s\n' "$executable" "$resolved"
    done > /run/agent-harbor/runtime-tools

    if ${pkgs.coreutils}/bin/touch /tmp/agent-harbor-unmanaged-write 2>/run/agent-harbor/unmanaged-tmp-error; then
      printf 'unexpectedly wrote to unmanaged shared tmp\n' > /run/agent-harbor/probe-error
      exit 1
    fi
    if ${pkgs.coreutils}/bin/touch /etc/agent-harbor-unmanaged-write 2>/run/agent-harbor/unmanaged-etc-error; then
      printf 'unexpectedly wrote to /etc\n' > /run/agent-harbor/probe-error
      exit 1
    fi

    ${pkgs.coreutils}/bin/touch /tmp/ah-zfs-clones/service-visible
    ${pkgs.coreutils}/bin/touch ${lib.escapeShellArg "${difficultBtrfsPath}/service-visible"}

    ${pkgs.systemd}/bin/systemd-notify --pid=parent --ready
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';

  testPackage = pkgs.symlinkJoin {
    pname = "agent-harbor-test-package";
    version = "0.5.0";
    paths = [
      fakeAh
      fakeSnapshotDaemon
    ];
  };

  # Keep negative module evaluations independent of the test driver's `pkgs`
  # fixpoint; feeding that package set back through eval-config recurses.
  evalPkgs = import ../.. {
    system = builtins.currentSystem;
    config.allowUnfree = true;
  };
  evalTestPackage =
    evalPkgs.runCommand "agent-harbor-eval-test-package-0.5.0"
      {
        version = "0.5.0";
      }
      ''
        mkdir -p "$out/bin"
      '';
  baseServiceConfig = {
    enable = true;
    package = evalTestPackage;
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
          fileSystems."/".device = "/dev/vda";
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
assert evaluationSucceeds { };
assert !evaluationSucceeds { package = evalPkgs.agent-harbor; };
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
            "/run/agent-harbor"
          ];
        };
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
  };

  testScript = ''
    import json
    import shlex

    socket_path = ${builtins.toJSON socketPath}
    difficult_path = ${builtins.toJSON difficultBtrfsPath}

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
            "stat -c '%a %U %G' /run/agent-harbor"
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

    with subtest("generated unit preserves confinement and literal specifiers"):
        unit = machine.succeed("systemctl cat ah-fs-snapshots-daemon.service")
        assert "PrivateTmp=false" in unit, unit
        assert "ProtectSystem=strict" in unit, unit
        assert "/tmp/ah-zfs-clones" in unit, unit
        assert "/srv/agent harbor/%%n/$NOT_EXPANDED" in unit, unit
        assert "--unrestricted" not in unit, unit

        machine.succeed(f"test -d {shlex.quote(difficult_path)}")
        private_tmp = machine.succeed(
            "systemctl show --property=PrivateTmp --value ah-fs-snapshots-daemon.service"
        ).strip()
        assert private_tmp == "no", private_tmp

    with subtest("daemon receives exact deduplicated allowlist arguments"):
        machine.wait_for_file("/run/agent-harbor/daemon-args")
        args = read_nul_args(machine, "/run/agent-harbor/daemon-args")
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
        tools = machine.succeed("cat /run/agent-harbor/runtime-tools").splitlines()
        assert tools == [
            "zfs=${pkgs.zfs}/bin/zfs",
            "btrfs=${pkgs.btrfs-progs}/bin/btrfs",
            "mount=${pkgs.util-linux}/bin/mount",
            "stat=${pkgs.coreutils}/bin/stat",
        ], tools

    with subtest("shared staging is visible and other shared paths stay read-only"):
        staging_metadata = machine.succeed(
            "stat -c '%a %U %G' /tmp/ah-zfs-clones"
        ).strip()
        assert staging_metadata == "755 root root", staging_metadata
        machine.succeed("test -e /tmp/ah-zfs-clones/service-visible")
        machine.succeed(
            f"test -e {shlex.quote(difficult_path + '/service-visible')}"
        )
        machine.fail("test -e /tmp/agent-harbor-unmanaged-write")
        machine.fail("test -e /etc/agent-harbor-unmanaged-write")
        machine.fail("test -e /run/agent-harbor/probe-error")
        machine.succeed("test -s /run/agent-harbor/unmanaged-tmp-error")
        machine.succeed("test -s /run/agent-harbor/unmanaged-etc-error")

    deny.start()

    with subtest("empty allowlists generate explicit deny-all arguments"):
        deny.wait_for_unit("ah-fs-snapshots-daemon.socket")
        deny.succeed("systemctl start ah-fs-snapshots-daemon.service")
        deny.wait_for_unit("ah-fs-snapshots-daemon.service")
        deny.wait_for_file("/run/agent-harbor/daemon-args")
        args = read_nul_args(deny, "/run/agent-harbor/daemon-args")
        assert args == [
            "--socket-path",
            socket_path,
            "--allowed-zfs-dataset",
            "/",
            "--allowed-btrfs-path",
            "/dev/null",
        ], args
        assert "--unrestricted" not in args, args
  '';
}
