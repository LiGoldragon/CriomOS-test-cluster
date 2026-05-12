# CriomOS Test Cluster

Independent fixture cluster for CriomOS and Horizon regression tests.

This repository is intentionally not `goldragon`. Its job is to prove
that CriomOS consumes projected Horizon data without production
cluster names, passwords, or host facts leaking into the platform
repo.

## Checks

```sh
nix flake check
```

The pure checks cover:

- Horizon projection from a Nota cluster proposal.
- rejection of multiple active tailnet controller servers.
- CriomOS network service rendering from `NodeServices`.
- CriomOS Nix client, builder, cache, and retention rendering from
  projected Horizon roles.
- Wi-Fi EAP-TLS client profile setup for a node that declares a Wi-Fi
  certificate.

## Prometheus

The Prometheus runner executes the same flake checks in a user
`systemd-run` sandbox on Prometheus:

```sh
nix run .#run-on-prometheus
```

The runner pushes the current `main` bookmark, then asks Prometheus to
evaluate the public GitHub flake under `PrivateUsers=yes`,
`ProtectHome=tmpfs`, and a fresh writable sandbox directory.
