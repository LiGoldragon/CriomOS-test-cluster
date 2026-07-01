# CriomOS-test-cluster — architecture

## Overview

This repository is an independent, synthetic fixture cluster (`fieldlab`) for
CriomOS, Horizon, and sandboxed Nix regression tests. Its one reason to exist is
to prove that **CriomOS consumes projected Horizon data** — never production
cluster names, passwords, or host facts. It is deliberately **not** `goldragon`
(the production cluster): its nodes exist only to exercise the projection to
config pipeline under test. The leak it guards against is any production fact
reaching the platform repo's tests.

## The projection pipeline it owns

`clusters/<cluster>.nota` (a cluster proposal) is projected by `horizon-cli` into
a per-node JSON projection. The committed `fixtures/horizon/<node>.json` artifacts
are pinned EQUAL to that projection by the `projections-match-fieldlab` check, so
reading a fixture IS reading the projection. Every test then builds a node by
feeding its projection to a real CriomOS `nixosSystem`
(`specialArgs.horizon = <projection>`) — the same way a production node is built.
A test is therefore **cluster-data-generated, not cluster-specific**: it is a
function of the cluster model.

## Two test altitudes

- **Static contract checks** (the bulk today): build a node config and assert
  static attributes — a service is enabled, a domain resolves, a known-host is
  present. Cheap, eval-only.
- **Booted VM tests** (`lib/mkVmTest.nix`, the generator): boot the generated
  guest under `runNixOSTest` and assert BEHAVIOUR. The author writes ONLY
  `(cluster, hostNode, vmNode, testScript)`; the guest OS, its size, its address,
  its accel, and every substrate fix flow from the projection plus the named
  `test-substrate` profile in CriomOS. The guest is a real CriomOS node built from
  its projection — never a hand-stub (Spirit `dqg3` / `aipc`).

## Auto-pickup: declaring a test-VM node IS getting a test

The flake stops hand-listing per-node checks. It iterates the Pod-on-a-`VmHost`
set the projection already names (`hostedPodNamesOf` in `lib/mkVmTest.nix`) and
generates one check per declared node. Each node gets the role-derived standard
fallback `testScript` (`lib/standardTest.nix`) unless it appears in the
`customTests` registry, which overrides with a bespoke single-concept script.
Capacity and subnet safety come free: `mkVmTest`'s `assertModel` fails at eval if
the hosted set over-subscribes the host's `VmHost` ceiling or subnet.

## Complex-OS and home-profile suite

A test boots ANY Pod-substrate node hosted on a `VmHost` host; the profile under
test is whatever the node's projection derives. A node's species drives its
`behavesAs.*` facets, which drive which CriomOS module trees light up:

- an **Edge** Pod lights the desktop tree (greetd/regreet, polkit, dbus,
  gnome-keyring, niri session) — a **complex OS** profile (`edge-desktop`). The
  `edge-desktop-boots-greeter` check boots it and asserts the display-manager plus
  desktop-support services.
- a lean **TestVm** Pod with `includeHome = true` keeps the home-manager base
  profile on an otherwise-minimal system — a **home profile** (`base-home`). The
  `base-home-activates` check asserts the per-user activation generation runs and a
  home program (`programs.git` producing `~/.config/git/config`) lands.

The generator reads the host's `VmHost` capability fully: `kvm` (Available means
KVM, Absent means a TCG software substrate) and `maximum_guests` (asserted against
the host's hosted Pod-substrate set; over-subscription fails at eval).
`includeHome` is the one cluster-decided flag (proposal decision 4), derived from
role by default and set explicitly only for the home-isolation case.

## The production-deploy smoke (deploy machinery, exactly once)

`lib/mkDeployTest.nix` keeps the REAL lojix production deploy path under a
hermetic, repeatable 2-node `runNixOSTest` — proving the *machinery*, not the
*content* of any role (that is the `mkVmTest` suite's job). A **deployer** node
runs the FIXED lojix daemon (lojix main, carrying the `<drv>^*` output-selector
fix the live e2e caught: build must realise the system, never activate the bare
`.drv`) configured the real way (`lojix-write-configuration` to rkyv to
`lojix-daemon`, both sockets at production modes). A **target** node is the
projected guest (mercury). The deployer submits a `FullOs` `Boot` Deploy of the
target's OWN projected config — `build_attribute` is the deploy flake's
`systemToplevel`, cluster-data-generated, never hand-written — and the test
asserts the target's `/nix/var/nix/profiles/system` becomes the lojix-deployed
closure, corroborated by the daemon's durable terminal deploy-job record read via
the ordinary CLI. It is psyche-scoped to GENERATION-ACTIVATION, not the full
`BootOnce` reboot (the deferred q35 part).

The integration walls are unblocked IN the test (Spirit `dqg3`), never papered
over: the daemon's `nix eval` / `nix build` run fully OFFLINE (the deploy flake
re-derives the target's system with a clavifaber stub so eval never fetches
`nota-derive`; the whole eval-plus-build closure is pinned into the deployer
store; `tarball-ttl` plus `use-registries=false` make `nix eval --refresh` re-use
the store-resident inputs by narHash); `<node>.<cluster>.criome` resolves via
`networking.hosts`; the deploy key plus accept-new host-key trust unblock ssh-ng
copy and the activation ssh; and the silent daemon is observed by polling the
target's own profile link plus the durable Query state.

## Making VM testing real (the cross-component witness)

The point of the booted-VM altitude is to make VM testing *real*: validate the
criome/lojix cluster with a fully-networked multi-node test substrate where the
spirit gate is authenticated end-to-end through one reusable interface. One
identical propagation test targets three substrates — a default hermetic,
host-untouched `runNixOSTest` VM cluster on prometheus; an opt-in durable
on-demand microvm node on prometheus (router and production untouched); and opt-in
DigitalOcean droplets for cross-machine validation. The gate accepts an authorized
head and rejects an unauthorized one fail-closed, building from 1-of-1 local
toward multi-machine quorum.

The **first witness that makes VM testing real** (`lib/mkCriomeAuthWitnessTest.nix`)
proves criome auth propagation through the persona router authenticating a real
Spirit record: the recorded spirit to criome to router to mirror chain, sourced
from a no-guardian Spirit daemon (the real Spirit daemon with its LLM
agent-guardian gate removed) and received by mirror. It includes the fail-closed
negative control where a head bearing no valid criome credential is refused, not
only the positive accept. It runs on prometheus on real booting VMs, and a Nix
store cache-hit must not be able to fake it: a re-run must actually boot the VMs
(Spirit `7let`).

## Spirit input topology

The flake carries two distinct Spirit surfaces; the distinction is load-bearing
and easy to misread:

- The **`spirit`** input (`github:LiGoldragon/spirit`) is the current production
  Spirit daemon (the schema-derived architecture). It carries the owner-only meta
  `ObserveHead` / `ObserveHeadObject` ops that the witness forwards, and is
  consumed only by the criome-auth witness check and app.
- The **`persona-spirit`** input (`github:LiGoldragon/persona-spirit`) is retained
  deliberately for the Spirit database upgrade and migration test. It builds the
  `persona-spirit-daemon` (and its `spirit` CLI) at two historical versions —
  v0.1.0 via the `persona-spirit-v010` input and v0.1.1 via `persona-spirit` main —
  feeding `spirit-upgrade-test-runner`, the `spirit-nspawn-toplevel`, the
  `spirit-nspawn-can-build` check, and the `nspawn-spirit-upgrade-on-prometheus`
  app. Those versions exist only in the `persona-spirit` repository; the newer
  `spirit` repository cannot supply them. `persona-spirit` is therefore a live,
  required input, not a legacy leftover.

## Constraints (non-negotiables)

- **Proof is first-hand reproducible evidence, not a green result** (Spirit
  `vcin`). For a VM or multi-component interaction test the witness is evidence the
  psyche can observe or re-run himself: a timestamped log for each causal link of
  the interaction plus a single command that reproduces the whole run. A passing
  or green result is not the deliverable; observable, reproducible proof is. A
  quiet local check is suspect unless it is a known heavyweight build.
- **No hand-stubbed horizon.** A guest is always built from a committed projection
  that `projections-match-fieldlab` pins to `horizon-cli`. Inventing a node's facts
  inline defeats the repo's entire reason to exist.
- **No production facts.** No `goldragon` node names, real domains, real passwords,
  or real host hardware. `source-constraints` enforces this against the CriomOS
  module source; keep it honest.
- **One concept per test, named for its invariant** (Spirit `xxgp`): a check's name
  states what it proves, carries a PATTERN comment, and asserts one thing.
- **Substrate constraints live in CriomOS, not here.** The writable-store / NSS /
  shell / serial / machine-type prebakes are the `test-substrate.nix` profile in
  CriomOS; `mkVmTest` applies it. They are never re-typed per test.
- **Tests are Nix-first and inputs are synthetic Nota.** Add constraints as
  `checks.*`; keep fixtures synthetic; use Nota for cluster inputs, never YAML.

## Prometheus runners

The Prometheus runners execute checks and builds inside a transient `systemd-run`
user sandbox (`PrivateUsers=yes`, `ProtectHome=tmpfs`, a fresh writable sandbox
directory), each first pushing the current `main` and then evaluating the public
GitHub flake:

- `nix run .#run-on-prometheus` — the flake checks.
- `nix run .#build-dune-on-prometheus` — the synthetic Pod node `dune` system
  toplevel.
- `nix run .#nspawn-dune-on-prometheus` — a container-aware `dune` toplevel started
  through the deployed `criomos-nspawn` interface, verifying hostname and system
  state, then torn down.
- `nix run .#run-criome-auth-on-prometheus` — the criome-auth witness.
- `nix run .#nspawn-spirit-upgrade-on-prometheus` — the Spirit database
  upgrade/migration test.

## Code map

- `clusters/*.nota` — synthetic cluster proposals (`fieldlab` plus its negative
  fixtures for multiple controllers and an out-of-cluster super-node).
- `fixtures/horizon/<node>.json` — committed per-node horizon projections, pinned
  EQUAL to `horizon-cli` by `projections-match-fieldlab`.
- `fixtures/secrets/` — synthetic sops fixture secret material.
- `lib/mkVmTest.nix` — the booted-VM test generator (auto-pickup, `assertModel`).
- `lib/standardTest.nix` — the role-derived standard fallback `testScript`.
- `lib/mkDeployTest.nix` — the lojix production-deploy smoke.
- `lib/mkCriomeAuthWitnessTest.nix` — the criome-auth propagation witness.
- `lib/deploy-flake.nix` — the offline deploy flake the deployer re-derives from.
- `checks/` — cluster-contract, full-module-contract, and source-constraint checks.
- `scripts/` — the Prometheus runners and `spirit-upgrade-test-runner`.
- `flake.nix` — checks, packages, and apps.
