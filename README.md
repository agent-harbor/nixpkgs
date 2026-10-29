# agent-harbor/nixpkgs

A fork of [NixOS/nixpkgs](https://github.com/NixOS/nixpkgs) that carries
[Agent Harbor](https://agent-harbor.com)'s package, NixOS module and NixOS test
on top of every popular upstream channel. For Nix users, this fork is where
Agent Harbor's Nix package comes from: there is nothing else to download.

This branch (`agent-harbor-ci`, the default) holds only this README and the
automation. The packages live on the channel branches below.

The fork follows the same model as
[`metacraft-labs/nixpkgs`](https://github.com/metacraft-labs/nixpkgs), and the
automation here is adapted from its `metacraft-ci` branch. The policy behind it
is the branching policy's
[nixpkgs Forks](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/latest/policies/branching-policy.md#nixpkgs-forks-upstream-channel-org-branches-2026-10-02)
section.

## Channels

Each channel branch is **named after the upstream channel it tracks, plus the
suffix `-agent-harbor`**, and is that upstream channel plus our commits. Pick
the one that matches the nixpkgs you already use.

| Branch | Tracks upstream | Built and checked on | Status |
|---|---|---|---|
| [`nixos-unstable-agent-harbor`](../../tree/nixos-unstable-agent-harbor) | `nixos-unstable` | x86_64-linux (+ NixOS test) | active |
| [`nixpkgs-unstable-agent-harbor`](../../tree/nixpkgs-unstable-agent-harbor) | `nixpkgs-unstable` | x86_64-linux, aarch64-darwin | active |
| [`nixos-26.05-agent-harbor`](../../tree/nixos-26.05-agent-harbor) | `nixos-26.05` | x86_64-linux (+ NixOS test), aarch64-darwin | active |
| [`nixpkgs-26.05-darwin-agent-harbor`](../../tree/nixpkgs-26.05-darwin-agent-harbor) | `nixpkgs-26.05-darwin` | aarch64-darwin | active |
| [`nixos-25.05-agent-harbor`](../../tree/nixos-25.05-agent-harbor) | `nixos-25.05` | x86_64-linux (+ NixOS test) | active (upstream end-of-life) |

`channels.json` is the authoritative list: it names the upstream channels, and
`"branchSuffix"` turns each into its branch. `nixos-26.05-agent-harbor` is also
checked on aarch64-darwin because nix-darwin configurations that share one
`nixpkgs` input with their NixOS hosts consume it there.

`nixos-25.05-agent-harbor` is kept although upstream no longer supports NixOS
25.05 (its channel stopped on 2026-01-02): a NixOS host is deliberately pinned
to 25.05, and it keeps receiving our package updates through this branch. It
gets no upstream security fixes. Upstream `nixos-25.05` no longer moves, so the
branch changes only when the series does. It is NixOS-only: no darwin
configuration uses 25.05. NixOS 25.11 is not kept (see "Frozen branches").

Consume a channel branch (through `flake.lock`, `nix-channel` or `nix profile`);
never branch from it or commit to it. Every sync rewrites it.

### Branch names: the transition from `agent-harbor-26.05` and `agent-harbor-25.05`

Before the channel branches, this fork kept one hand-maintained branch per NixOS
release, named with a prefix (`agent-harbor-25.05`, `agent-harbor-25.11`,
`agent-harbor-26.05`), and none of them was synced. They are replaced by the
`-agent-harbor` channel branches above.

**The old names `agent-harbor-26.05` and `agent-harbor-25.05` were frozen on
2026-10-29.** From 2026-10-13 until 2026-10-28 each sync of `nixos-26.05`
pushed the same revision to `nixos-26.05-agent-harbor` and to
`agent-harbor-26.05` in one atomic push, and archived it under both;
`nixos-25.05` did the same for `agent-harbor-25.05`. On 2026-10-29 the
`legacyBranches` flag in `channels.json` was turned off (`"publish": false`,
commit `490977d`), so only the `-agent-harbor` branches move now. Use the
`-agent-harbor` names.

The old branches are not deleted, because a user's `flake.lock` may still name
them. Each one stays at its final tip, which is also tagged
`archive/branch/<name>`:

| Old name | Frozen at | Same revision as |
|---|---|---|
| `agent-harbor-26.05` | `18c2fa4c6d384ddd9c42e480d41c2dd4bc73e692` | `nixos-26.05-agent-harbor` on 2026-10-29 |
| `agent-harbor-25.05` | `0e8079b46773443f93a20a6c2552c4bffe21cecc` | `nixos-25.05-agent-harbor` on 2026-10-29 |

### Frozen branches

- `agent-harbor-25.11` tracks a NixOS release that upstream no longer supports
  and that nothing here uses. It stopped moving when the channel branches were
  introduced, and keeps its last tip as the tag
  `archive/branch/agent-harbor-25.11`. It is not deleted: a configuration may
  still pin it.
- Every revision a branch of this fork held before the channel branches existed
  stays fetchable: the last pre-migration tips of `agent-harbor` (then on
  `nixos-25.05`), `agent-harbor-26.05` and `agent-harbor-25.05` are kept under
  `refs/archive/<branch>/<timestamp>`.

### Migration record (2026-10-13)

- Pre-migration tips archived as `refs/archive/<branch>/20261013T095236Z`:
  `agent-harbor` `18a7e7f1`, `agent-harbor-26.05` `f25c5cde`,
  `agent-harbor-25.05` `07d075da`; `agent-harbor-25.11` frozen at `009b77a9`
  (tag `archive/branch/agent-harbor-25.11`). `agent-harbor` was then rewritten
  to the clean series (`0184deb4`, upstream `nixos-unstable` plus 12 commits).
- First publication of the channel branches:
  [run 38384670080](../../actions/runs/38384670080) published
  `nixos-unstable-agent-harbor` and `nixos-25.05-agent-harbor` (with
  `agent-harbor-25.05`; one fixup). Its aarch64-darwin builds failed on a
  bash 3.2 incompatibility in `scripts/sync.sh`, fixed in `773e4baf`;
  [run 38386090018](../../actions/runs/38386090018) then published
  `nixpkgs-unstable-agent-harbor`, `nixos-26.05-agent-harbor` (with
  `agent-harbor-26.05`) and `nixpkgs-26.05-darwin-agent-harbor`, and closed the
  three failure issues.

## Packages

| Attribute | Version | Platforms | Upstream status |
|---|---|---|---|
| `agent-harbor` (`ah`) | 0.6.7 | x86_64-linux, aarch64-darwin | not submitted: prebuilt unfree binary |

The series also carries the NixOS module `services.agent-harbor`
(`nixos/modules/services/misc/agent-harbor.nix`: the `ah-fs-snapshots-daemon`
socket and service, and installed-version activation) and its test
`nixosTests.agent-harbor`.

## Installing

`agent-harbor` is unfree: set `nixpkgs.config.allowUnfree = true`, or
`NIXPKGS_ALLOW_UNFREE=1` together with `--impure` on the command line.

**NixOS with flakes.** The module is part of the tree, so use the channel
branch as your `nixpkgs` (pick the branch named like the release you run):

```nix
{
  inputs.nixpkgs.url = "github:agent-harbor/nixpkgs/nixos-26.05-agent-harbor";

  outputs = { nixpkgs, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        {
          nixpkgs.config.allowUnfree = true;
          services.agent-harbor.enable = true;
        }
      ];
    };
  };
}
```

Updates arrive with `nix flake update nixpkgs` and `nixos-rebuild switch`.

**Nix on any other Linux, or macOS:**

```sh
NIXPKGS_ALLOW_UNFREE=1 nix profile install --impure \
  github:agent-harbor/nixpkgs/nixpkgs-unstable-agent-harbor#agent-harbor
nix profile upgrade --all --impure     # later, to update
```

Never install from a product repository's own flake at `dev`: that is
unreleased code under a release's name.

## How the fork works

### One source of truth: the `agent-harbor` branch

[`agent-harbor`](../../tree/agent-harbor) is upstream `nixos-unstable` plus
**one clean commit series**: the commits that add or update our package, its
NixOS module and its NixOS test, and nothing else. It may only touch the path
prefixes in `channels.json`'s `"seriesPaths"` (`pkgs/by-name/`,
`nixos/modules/`, `nixos/tests/`); the automation refuses to run otherwise. The
series is exactly what `agent-harbor` has that upstream `master` does not (their
merge base is where it starts), so no marker commit or separate base ref is
needed.

Every channel branch is **generated** from it: the series rebased onto that
upstream channel. Nobody commits to a channel branch directly; a commit there
is overwritten by the next sync. Publishing a rebased channel branch is a
force-update, which the branching policy allows for the `-agent-harbor`
branches of this fork only, and only through this automation.

Why a rebased series and not merges or a patch directory:

- **The delta stays reviewable.** `git log upstream/nixos-unstable..agent-harbor`
  is our whole difference from upstream, one commit per change, in the form
  an upstream PR takes. Merges would bury it under upstream history.
- **It is a real nixpkgs tree.** The package and the module are developed and
  tested with the ordinary tools (`nix build --impure .#agent-harbor`,
  `nix build --impure .#nixosTests.agent-harbor`), which a patch directory kept outside
  the tree would not allow.
- **One series, many channels.** Carrying the package per release branch is
  how the delta drifted apart before (the 25.05, 25.11 and 26.05 branches each
  carried a different subset until they were synced by hand); generating every
  channel from one series cannot.

### The automation

[`.github/workflows/sync-channels.yml`](.github/workflows/sync-channels.yml)
runs **daily at 04:23 UTC** and on demand. For each channel in
`channels.json`, independently
([`sync-channel.yml`](.github/workflows/sync-channel.yml)):

1. **rebase** the series onto the upstream channel head. A conflict fails
   the channel. So does a rebase that merges without a conflict but changes
   upstream by anything other than exactly the lines the series changes (see
   "Per-channel fixups").
2. **build** every package the series touches, on each system the channel
   serves (GitHub-hosted `ubuntu-latest` and `macos-latest`). A package whose
   `meta.platforms` excludes a system is skipped there. Then
   [`scripts/smoke.sh`](scripts/smoke.sh) uses it: `ah --version` must report
   the packaged version (on macOS this loads the bundled dylibs), the runtime
   helpers must be on `ah`'s private PATH (the Claude Code ACP adapter only
   where the channel packages one; `nixos-25.05` does not), and on Linux
   `ah-fs-snapshots-daemon --help` must offer the allowlist flags the module
   requires. On a `nixos-*` channel, the Linux build also runs
   `nixosTests.agent-harbor` (a VM test, with the runner's KVM; without KVM it
   is only evaluated, with a warning).
3. **publish** only if every build of that channel is green: force-push
   `<channel>-agent-harbor` (and, while `legacyBranches.publish` is `true`, the
   channel's `legacyBranch`) in one atomic push, with a lease on
   the tip each had when the run started. **A broken rebase or build never
   replaces a working branch.** Each published revision is also kept under
   `refs/archive/<branch>/<timestamp>` for every name it is published under, so
   the revision a user's `flake.lock` names stays fetchable after the branch
   moves on. These refs are never deleted. The step then reads every pushed
   ref back from GitHub.
4. **verify** the published branch the way a user installs from it:
   `nix build github:agent-harbor/nixpkgs/<channel>-agent-harbor#agent-harbor`,
   then `nix profile install` into a throwaway profile and the same smoke test.
   While `legacyBranches.publish` is `true` it also checks that the channel's
   `legacyBranch` resolves to the same revision. A failure here cannot un-publish, so it opens
   the channel's issue.

After `nixos-unstable-agent-harbor` publishes, `agent-harbor` itself is moved
onto the same upstream commit (again with a lease, so a push made during the
run wins). Pull it with `git pull --rebase`.

A channel whose rebase or build fails **opens an issue** labelled
[`upstream-sync`](../../issues?q=label%3Aupstream-sync), titled
`Channel sync failed: <channel>` (the upstream channel name); later failures
comment on it, and the next successful publish closes it. A new upstream NixOS
release that `channels.json` does not list opens `New NixOS release: nixos-YY.MM`.

`scripts/sync.sh` holds every step, so a run can be reproduced locally:

```sh
scripts/sync.sh plan                     # prints series_base, series_len, series_head
export SERIES_BASE=… SERIES_LEN=… SERIES_HEAD=…
scripts/sync.sh rebase nixos-26.05       # upstream channel name; prints upstream_sha, result_sha
export UPSTREAM_SHA=… RESULT_SHA=…
scripts/sync.sh checkout && scripts/sync.sh build x86_64-linux nixos-26.05   # tree in /tmp/nixpkgs
```

Channel pushes use a write deploy key of this repository (secret
`CHANNEL_PUSH_KEY`). The workflow's own `GITHUB_TOKEN` cannot be used: GitHub
refuses a token-authenticated push whose commits change `.github/workflows/`,
and every rebase onto a newer upstream carries upstream's workflow changes.

**Only this automation moves a channel branch.** The repository ruleset
`agent-harbor-channel-branches` covers `refs/heads/*-agent-harbor`. It refuses
creation, update, force-update and deletion to everyone, administrators
included, except the repository's deploy keys. `CHANNEL_PUSH_KEY` is the
fork's only write deploy key. GitHub's deploy-key bypass covers every deploy
key of a repository, so adding another write deploy key would widen the
exception: don't. The ruleset does not cover `agent-harbor` (the authoring
branch, which the sync moves with a lease) or the transition name
`agent-harbor-26.05`. It comes from the organization's governance root in
[`agent-harbor/infra`](https://github.com/agent-harbor/infra)
(`terraform/github/agent-harbor-governance-prod/governance.nix`, with the
bypass recorded as the documented exception in `root.nix`'s
`noBypassPolicy`). Change it there, not in the repository settings.

## Maintaining the package

**Releasing a new version** is part of the release (a release is not done
while a Nix user cannot get it):

```sh
git clone --depth=20 --branch agent-harbor https://github.com/agent-harbor/nixpkgs
cd nixpkgs
pkgs/by-name/ag/agent-harbor/update.sh          # or: LATEST_VER=0.6.8 pkgs/by-name/ag/agent-harbor/update.sh
NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#agent-harbor && ./result/bin/ah --version
git commit -am 'agent-harbor: 0.6.7 -> 0.6.8'
git push origin agent-harbor
gh workflow run sync-channels.yml -R agent-harbor/nixpkgs   # don't wait for the daily run
```

**Changing the module** is the same flow: commit to `agent-harbor`, with the
NixOS test updated alongside (`nix build --impure .#nixosTests.agent-harbor`;
`--impure` because the test evaluates a second package set for
`builtins.currentSystem`).
A commit is written the way an upstream nixpkgs pull request expects it
(`agent-harbor: …`, `nixos/agent-harbor: …`), touching only the package, the
module, the test and their one-line registrations (`module-list.nix`,
`all-tests.nix`).

## Upstreaming: the fork is a waiting room

When the package or the module is accepted into upstream nixpkgs, **it is
removed from this fork** in the same change that moves the channels past the
upstream commit carrying it, so no user sees it disappear before it reappears.
In practice the rebase then conflicts (both sides add the same file) and the
sync opens an issue: drop those commits from `agent-harbor` and re-run the
workflow.

Everything here is therefore one of:

1. waiting on an open upstream PR (linked in its file);
2. genuinely unsuitable for upstream (the reason is in its file; for the
   package today: it repackages an unfree prebuilt release);
3. a bug in this process, if it is neither.

### Per-channel fixups

A rebase across release branches can merge without a conflict and still be
wrong: git aligns a hunk on context lines and may keep a line the target branch
does not have. Rebasing the series from `nixos-unstable` onto `nixos-25.05`
does exactly that: the one-line `module-list.nix` registration also re-adds
`./services/matrix/tuwunel.nix`, a module 25.05 lacks, which would break every
NixOS evaluation. The sync therefore checks every channel: the lines the
rebased branch adds and removes relative to upstream must equal the lines the
series adds and removes relative to its own base.

When a channel cannot pass that check by rebasing alone, it lists **fixups** in
`channels.json`: `git format-patch` files under `fixups/<channel>/`, applied
with `git am` (no three-way fallback) on top of the rebased series, only when
the plain rebase fails the check, and the check runs again after them. A fixup
restores the series' change; it never adds a different one. The published
branch is then upstream, the series, and the fixup commits. Today:

| Channel | Fixup | Why |
|---|---|---|
| `nixos-25.05` | `0001-nixos-25.05-keep-tuwunel-out-of-module-list.nix.patch` | drops the `tuwunel.nix` line the rebase carries in |

A run whose rebase no longer needs a channel's fixups says so in a notice: drop
them from `channels.json`. A fixup that no longer applies fails the channel like
a conflict.

To write one: rebase the series locally (`scripts/sync.sh rebase <channel>`
leaves the tree in `/tmp/nixpkgs`, branch `result`), correct the file, commit,
`git format-patch -1 --zero-commit -o fixups/<channel>/`, and list the file.

## Adding and retiring channels

A new NixOS release (`nixos-YY.MM` with its `nixpkgs-YY.MM-darwin`) is added
to `channels.json` with `"status": "active"`; the next run creates both
branches, `nixos-YY.MM-agent-harbor` and `nixpkgs-YY.MM-darwin-agent-harbor`.
When upstream stops supporting a release, set its entries to
`"status": "deprecated"`: the branch is no longer synced, and is **not
deleted**, because a user's `flake.lock` may still name it. List it in the
table above as deprecated.

## Other branches

- `agent-harbor`: where our commits are authored (see above).
- `agent-harbor-26.05`, `agent-harbor-25.05`: the old names of
  `nixos-26.05-agent-harbor` and `nixos-25.05-agent-harbor`, published alongside
  them until 2026-10-28 and frozen on 2026-10-29 (see "Branch names").
- `agent-harbor-25.11`: frozen (see "Frozen branches").
- `master`: the former default branch, an old upstream `master` plus one commit
  that moved upstream's CI from Cachix to Attic. It carries nothing of the
  package and is not synced.
- Every other branch is an upstream branch GitHub copied when the fork was
  created; none is maintained.
