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
- rejection of a pod node whose super-node is outside the cluster.
- CriomOS network service rendering from `NodeServices`.
- CriomOS Nix client, builder, cache, and retention rendering from
  projected Horizon roles.
- full CriomOS aggregate module instantiation with home disabled for
  synthetic client and builder nodes.
- Wi-Fi EAP-TLS client profile setup for a node that declares a Wi-Fi
  certificate.
- CriomOS module source constraints against production host facts and
  node-name predicates.

## Prometheus

The Prometheus runner executes the same flake checks in a user
`systemd-run` sandbox on Prometheus:

```sh
nix run .#run-on-prometheus
```

The runner pushes the current `main` bookmark, then asks Prometheus to
evaluate the public GitHub flake under `PrivateUsers=yes`,
`ProtectHome=tmpfs`, and a fresh writable sandbox directory.

The heavier toplevel build runner is separate from the default check
runner:

```sh
nix run .#build-dune-on-prometheus
```

It builds the synthetic Pod node `dune` system toplevel from the public GitHub
flake inside the same kind of transient sandbox.

The nspawn smoke runner builds a container-aware `dune` toplevel on Prometheus,
starts it through the deployed `criomos-nspawn` interface from the invoking
user, verifies the container hostname and system state, and tears the machine
down:

```sh
nix run .#nspawn-dune-on-prometheus
```
