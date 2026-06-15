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
- **Booted VM tests** (`lib/mkVmTest.nix`, the C4 generator): boot the
  generated guest under `runNixOSTest` and assert BEHAVIOUR (sshd answers, a
  unit comes up). The author writes ONLY `(cluster, hostNode, vmNode,
  testScript)`; the guest OS, its size, its address, and every substrate fix
  flow from the projection plus the named `test-substrate` profile in CriomOS.
  The guest is a real CriomOS node built from its projection — never a
  hand-stub (Spirit [dqg3]/[aipc]).

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
