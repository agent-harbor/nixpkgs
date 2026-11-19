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

  # Stand-ins for a daemon that supports `--idle-exit-after`, one per package
  # generation. They test the module and systemd side of idle exit: the flag
  # reaches a daemon that advertises it, a package switch leaves the running
  # daemon alone, and after a clean exit the socket starts the switched-to
  # binary. When to exit is the daemon's own logic (tested in agent-harbor);
  # here the test decides, by creating the release file.
  mkIdleExitDaemon =
    generation:
    pkgs.writeShellScriptBin "ah-fs-snapshots-daemon" ''
      set -eu

      if [ "''${1:-}" = "--help" ]; then
        printf '%s\n' \
          'Usage: ah-fs-snapshots-daemon [OPTIONS]' \
          '  --allowed-zfs-dataset <DATASET>' \
          '  --allowed-btrfs-path <PATH>' \
          '  --idle-exit-after <IDLE_EXIT_AFTER>'
        exit 0
      fi

      printf '%s\0' "$@" > /run/agentharborfsd/daemon-args-${generation}
      echo ${generation} >> /run/agentharborfsd/generations-started
      ${pkgs.systemd}/bin/systemd-notify --pid=parent --ready
      while [ ! -e /run/agentharborfsd/release-${generation} ]; do
        ${pkgs.coreutils}/bin/sleep 0.2
      done
      exit 0
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
  idleFirstPackage = mkVersionlessTestPackage "agent-harbor-idle-first" (mkIdleExitDaemon "first");
  idleSecondPackage = mkVersionlessTestPackage "agent-harbor-idle-second" (mkIdleExitDaemon "second");

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
  # Releases before 0.4.0 have no filesystem allowlists and must be refused.
  # (This used to be the default package; it is now 0.6.0, asserted below.)
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

  # The release package itself, built from a tarball with the published
  # x86_64-linux portable layout, so the test checks what the package
  # installs from a release without downloading one: the executables `ah`
  # looks for beside itself, and the approval polkit action. Each placeholder
  # executable prints its own name.
  approvalActionId = "org.agentharbor.approval.confirm-person";
  # The action's policy as agent-harbor ships it
  # (packaging/linux/polkit/org.agentharbor.approval.policy): the action id
  # and auth_self (the user's own password, every time).
  fixturePolicy = pkgs.writeText "org.agentharbor.approval.policy" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE policyconfig PUBLIC
     "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
    <policyconfig>
      <vendor>Agent Harbor</vendor>
      <action id="${approvalActionId}">
        <description>Confirm it is you deciding an Agent Harbor approval request</description>
        <message>Agent Harbor needs your password to confirm that you, not an agent, are deciding an approval request or opening its page.</message>
        <defaults>
          <allow_any>auth_self</allow_any>
          <allow_inactive>auth_self</allow_inactive>
          <allow_active>auth_self</allow_active>
        </defaults>
      </action>
    </policyconfig>
  '';
  besideAh = [
    "oq"
    "ah-mcp-connector"
    "llm-api-proxy"
  ];
  fixtureRelease = pkgs.runCommand "agent-harbor-portable-fixture-x86_64-linux.tar.gz" { } ''
    root=agent-harbor-portable-x86_64-linux
    mkdir -p "$root/bin" "$root/share/polkit-1/actions"
    for bin in ah ah-fs-snapshots-daemon ${lib.escapeShellArgs besideAh}; do
      printf '#!${pkgs.runtimeShell}\necho %s\n' "$bin" > "$root/bin/$bin"
      chmod 0755 "$root/bin/$bin"
    done
    cp ${fixturePolicy} "$root/share/polkit-1/actions/org.agentharbor.approval.policy"
    tar -czf "$out" "$root"
  '';
  # From evalPkgs, which allows the unfree package; without the ACP adapter,
  # which this test does not use.
  releasePackage =
    (evalPkgs.agent-harbor.override {
      claude-code-acp = null;
      claude-agent-acp = null;
    }).overrideAttrs
      {
        src = fixtureRelease;
        sourceRoot = "agent-harbor-portable-x86_64-linux";
      };
  # The same release without one of them: the package must refuse to build
  # rather than ship an `ah` that cannot start it. Each value is the build
  # failure's log (testers.testBuildFailure), read by the test driver.
  releaseWithout =
    path:
    evalPkgs.testers.testBuildFailure (
      releasePackage.overrideAttrs (old: {
        postUnpack = (old.postUnpack or "") + "rm agent-harbor-portable-x86_64-linux/${path}\n";
      })
    );
  refusals = lib.listToAttrs (
    map (bin: lib.nameValuePair bin "${releaseWithout "bin/${bin}"}/testBuildFailure.log") besideAh
    ++ [
      (lib.nameValuePair "polkit" "${releaseWithout "share/polkit-1/actions/org.agentharbor.approval.policy"}/testBuildFailure.log")
    ]
  );

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
assert evaluationSucceeds { package = evalPkgs.agent-harbor; };
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
assert evaluationSucceeds { snapshotDaemon.idleExitAfter = null; };
assert evaluationSucceeds { snapshotDaemon.idleExitAfter = "30s"; };
assert !evaluationSucceeds { snapshotDaemon.idleExitAfter = "0"; };
assert !evaluationSucceeds { snapshotDaemon.idleExitAfter = "10 minutes"; };
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

    idle = {
      services.agent-harbor = {
        enable = true;
        package = idleFirstPackage;
        snapshotDaemon = {
          accessGroup = "ah-idle-access";
          idleExitAfter = "45s";
        };
      };
      # The package a later switch installs.
      specialisation.next.configuration.services.agent-harbor.package = lib.mkForce idleSecondPackage;
      # The installed-version activation realises the package with
      # snapshotDaemon's nix-store to root it, and in a test VM that store
      # database does not list the package ("path ... is not valid", measured
      # 2026-11-12), so switch-to-configuration would fail before reaching
      # the service. These subtests are about the service, not activation.
      system.activationScripts.agentHarborActivateInstalledVersion = lib.mkForce "";
    };

    packaged = {
      services.agent-harbor = {
        enable = true;
        package = releasePackage;
        snapshotDaemon.accessGroup = "ah-packaged-access";
      };
      # polkit reads the actions of the packages in environment.systemPackages
      # (share/polkit-1 is linked into /run/current-system/sw when it is
      # enabled); the approval action needs it running.
      security.polkit.enable = true;
      # As on the idle node: the test VM's store database does not list the
      # package, so the installed-version activation fails at boot. These
      # subtests are about what the package installs, not activation.
      system.activationScripts.agentHarborActivateInstalledVersion = lib.mkForce "";
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

    with subtest("a daemon without --idle-exit-after starts without it, and says so"):
        journal = machine.succeed("journalctl -b -u ah-fs-snapshots-daemon.service")
        assert "does not support --idle-exit-after" in journal, journal

    idle.start()

    def idle_daemon_pid():
        return idle.succeed(
            "systemctl show --property=MainPID --value ah-fs-snapshots-daemon.service"
        ).strip()

    with subtest("an idle-exit capable daemon receives the configured period"):
        idle.wait_for_unit("ah-fs-snapshots-daemon.socket")
        idle.succeed("systemctl start ah-fs-snapshots-daemon.service")
        idle.wait_for_unit("ah-fs-snapshots-daemon.service")
        args = read_nul_args(idle, "/run/agentharborfsd/daemon-args-first")
        assert args[-2:] == ["--idle-exit-after", "45s"], args
        assert args[:2] == ["--socket-path", socket_path], args

    with subtest("a package switch leaves the running daemon alone"):
        first_pid = idle_daemon_pid()
        idle.succeed(
            "/run/current-system/specialisation/next/bin/switch-to-configuration test"
        )
        assert idle_daemon_pid() == first_pid, "the switch restarted the daemon"
        unit = idle.succeed("systemctl cat ah-fs-snapshots-daemon.service")
        assert "agent-harbor-idle-second" in unit, unit
        idle.fail("test -e /run/agentharborfsd/daemon-args-second")

    with subtest("after an idle exit the next connection starts the switched-to binary"):
        idle.succeed("touch /run/agentharborfsd/release-first")
        idle.wait_until_succeeds(
            "systemctl show --property=SubState --value ah-fs-snapshots-daemon.service"
            " | grep -qx dead"
        )
        result = idle.succeed(
            "systemctl show --property=Result --value ah-fs-snapshots-daemon.service"
        ).strip()
        assert result == "success", result
        # A clean exit is not restarted by Restart=on-failure; only a client
        # starts the daemon again, through the socket that stayed listening.
        idle.succeed("sleep 7")
        idle.fail("systemctl is-active --quiet ah-fs-snapshots-daemon.service")
        idle.succeed("systemctl is-active --quiet ah-fs-snapshots-daemon.socket")
        idle.succeed(
            "${pkgs.python3}/bin/python3 -c "
            + shlex.quote(
                "import socket; "
                f"sock = socket.socket(socket.AF_UNIX); sock.connect({socket_path!r}); sock.close()"
            )
        )
        idle.wait_for_file("/run/agentharborfsd/daemon-args-second")
        idle.wait_for_unit("ah-fs-snapshots-daemon.service")
        generations = idle.succeed("cat /run/agentharborfsd/generations-started").split()
        assert generations == ["first", "second"], generations

    with subtest("the package refuses a release without them"):
        refusals = json.loads(${builtins.toJSON (builtins.toJSON refusals)})
        # (Not named `log`: the driver's logger is a global of that name.)
        for name in ${builtins.toJSON besideAh}:
            build_log = open(refusals[name]).read()
            assert f"no '{name}' beside 'ah'" in build_log, (name, build_log)
        build_log = open(refusals["polkit"]).read()
        assert "no share/polkit-1/actions/org.agentharbor.approval.policy" in build_log, build_log

    packaged.start()
    packaged.wait_for_unit("multi-user.target")

    with subtest("oq, ah-mcp-connector and llm-api-proxy are on PATH beside the package's ah"):
        libexec = "${releasePackage}/libexec/agent-harbor"
        packaged.succeed(f"test -x {libexec}/ah")
        ah = packaged.succeed("command -v ah").strip()
        assert ah == "/run/current-system/sw/bin/ah", ah
        for name in ${builtins.toJSON besideAh}:
            on_path = packaged.succeed(f"command -v {name}").strip()
            assert on_path == f"/run/current-system/sw/bin/{name}", (name, on_path)
            resolved = packaged.succeed(f"readlink -f {on_path}").strip()
            assert resolved == f"{libexec}/{name}", (name, resolved)
            output = packaged.succeed(f"{name}").strip()
            assert output == name, (name, output)

    with subtest("the approval polkit action is installed and polkit knows it"):
        packaged.succeed(
            "test -f /run/current-system/sw/share/polkit-1/actions/org.agentharbor.approval.policy"
        )
        action = packaged.succeed(
            "pkaction --verbose --action-id ${approvalActionId}"
        )
        lines = action.splitlines()
        assert lines[0] == "${approvalActionId}:", action
        fields = dict(
            (key.strip(), value.strip())
            for key, _, value in (line.partition(":") for line in lines[1:] if line.strip())
        )
        assert fields.get("vendor") == "Agent Harbor", action
        # auth_self, every time: the person's own password, never cached.
        for implicit in ("implicit any", "implicit inactive", "implicit active"):
            assert fields.get(implicit) == "auth_self", (implicit, action)

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
