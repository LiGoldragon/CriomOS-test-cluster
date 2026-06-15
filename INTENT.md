# CriomOS-test-cluster — intent

What the psyche wants this repo to be, upstream of its code.

## The one thing

This repo proves that **CriomOS consumes projected Horizon data** — never
production cluster names, passwords, or host facts. It is deliberately NOT
`goldragon`: it is a synthetic fixture cluster (`fieldlab`) whose nodes exist
only to exercise the projection -> config pipeline under test. The leak it
guards against is any production fact reaching the platform repo's tests.

## The pipeline it owns

`clusters/<cluster>.nota` (a cluster proposal) is projected by `horizon-cli`
into a per-node JSON projection; the committed `fixtures/horizon/<node>.json`
artifacts are pinned EQUAL to that projection by the
`projections-match-fieldlab` check, so reading a fixture IS reading the
projection. Every test then builds a node by feeding its projection to a real
CriomOS `nixosSystem` (`specialArgs.horizon = <projection>`) — the same way a
production node is built. A test is therefore **cluster-data-generated, not
cluster-specific**: it is a function of the cluster model.

## Two test altitudes

- **Static contract checks** (the bulk, today): build a node config and assert
  static attributes — a service is enabled, a domain resolves, a known-host is
  present. Cheap, eval-only.
- **Booted VM tests** (`lib/mkVmTest.nix`, the generator): boot the generated
  guest under `runNixOSTest` and assert BEHAVIOUR (sshd answers, a desktop
  service comes up, a home generation activates). The author writes ONLY
  `(cluster, hostNode, vmNode, testScript)`; the guest OS, its size, its
  address, its accel, and every substrate fix flow from the projection plus the
  named `test-substrate` profile in CriomOS. The guest is a real CriomOS node
  built from its projection — never a hand-stub (Spirit [dqg3]/[aipc]).

## Complex-OS + home-profile suite (the headline)

A test boots ANY Pod-substrate node hosted on a `VmHost` host (relaxed from "a
lean TestVm"): the PROFILE under test is whatever the node's projection derives.
A node's species → `behavesAs.*` facets → which CriomOS module trees light up:

- an **Edge** Pod lights the desktop tree (greetd/regreet, polkit, dbus,
  gnome-keyring, niri session) — a **complex OS** profile. `edge-desktop` in
  `fieldlab.nota`; the `edge-desktop-boots-greeter` check boots it and asserts
  the display-manager + desktop-support services.
- a lean **TestVm** Pod with `includeHome = true` keeps the home-manager base
  profile on an otherwise-minimal system — a **home profile**. `base-home`; the
  `base-home-activates` check asserts the per-user activation generation runs
  and a home program (`programs.git` → `~/.config/git/config`) lands.

The generator reads the host's `VmHost` capability fully: `kvm` (Available →
KVM, Absent → a TCG software substrate) and `maximum_guests` (asserted against
the host's hosted Pod-substrate set; over-subscription fails at eval). The home
toggle is the one cluster-decided flag (proposal decision 4 — `includeHome`),
derived from role by default and set explicitly only for the home-isolation
case.

## The production-deploy smoke (the deploy MACHINERY, exactly once)

`lib/mkDeployTest.nix` keeps the REAL lojix production deploy path under a
hermetic, repeatable 2-node `runNixOSTest` — proving the *machinery*, not the
*content* of any role (that is the mkVmTest suite's job). A **deployer** node
runs the FIXED lojix daemon (lojix main, the `<drv>^*` output-selector fix that
the live e2e caught) configured the real way (`lojix-write-configuration` →
rkyv → `lojix-daemon`, both sockets at production modes); a **target** node is
the projected guest (mercury). The deployer submits a `FullOs` `Boot` Deploy of
the target's OWN projected config — `build_attribute` = the deploy flake's
`systemToplevel`, cluster-data-generated, never hand-written — and the test
asserts the target's `/nix/var/nix/profiles/system` becomes the lojix-deployed
closure (a real `nixos-system-<node>`, the `<drv>^*` fix held, never the bare
`.drv`), corroborated by the daemon's durable terminal deploy-job record read
via the ordinary CLI. Psyche-scoped to GENERATION-ACTIVATION, not the full
BootOnce reboot (the deferred q35 part).

The integration walls are unblocked IN the test (Spirit [dqg3]), never papered
over: the daemon's `nix eval`/`nix build` run fully OFFLINE (the deploy flake
re-derives the target's system with a clavifaber stub so eval never fetches
`nota-derive`; the whole eval+build closure is pinned into the deployer store;
`tarball-ttl` + `use-registries=false` make `nix eval --refresh` re-use the
store-resident inputs by narHash); `<node>.<cluster>.criome` resolves via
`networking.hosts`; the deploy key + accept-new host-key trust unblock ssh-ng
copy AND the activation ssh; and the silent daemon is observed by polling the
target's own profile link plus the durable Query state. This is the one place
the production path that caught the `.drv` bug runs under repeatable test.

## Non-negotiables

- **No hand-stubbed horizon.** A guest is always built from a committed
  projection that `projections-match-fieldlab` pins to `horizon-cli`. Inventing
  a node's facts inline defeats the repo's entire reason to exist.
- **No production facts.** No `goldragon` node names, real domains, real
  passwords, or real host hardware. `source-constraints` enforces this against
  the CriomOS module source; keep it honest.
- **One concept per test, named for its invariant** (Spirit [xxgp]): a check's
  name states what it proves, carries a PATTERN comment, and asserts one thing.
- **Substrate constraints live in CriomOS, not here.** The writable-store /
  NSS / shell / serial / machine-type prebakes are the `test-substrate.nix`
  profile in CriomOS; `mkVmTest` applies it. They are never re-typed per test.
