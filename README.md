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

## Current Lojix certification

Lojix release certification does not use the repository-wide historical
migration sweep. Its disposable current-system surface is limited to the
pinned Lojix candidate with the current CriomOS input and that input's locked
CriomOS-home revision:

```sh
nix build path:$PWD#checks.x86_64-linux.lojix-deploy-smoke --no-link --print-build-logs
nix build path:$PWD#checks.x86_64-linux.vm-base-home --no-link --print-build-logs
```

`lojix-deploy-smoke` proves the daemon admits a current host deployment and
that the synthetic target's system profile becomes the exact deployed system
closure. `vm-base-home` is the narrow current CriomOS-home activation witness.
Both run only disposable fixture VMs. They do not contact or mutate a
production node or user environment.

Do not represent `nix flake check` as a current Lojix release result. Its
retired Persona/Upgrade migration checks are separate repository maintenance;
see `NON_IDEAL_AGENTS.md` for the boundary.

## Prometheus

The Prometheus runner executes the same flake checks in a user
`systemd-run` sandbox on Prometheus:

```sh
nix run .#run-on-prometheus
```

The runner pushes `main` by default, then asks Prometheus to evaluate that
immutable public GitHub revision under `PrivateUsers=yes`, `ProtectHome=tmpfs`,
and a fresh writable sandbox directory. A published review fixture uses the
same path without a temporary input override:

```sh
nix run .#run-on-prometheus -- prometheus.goldragon.criome external-fixture-reconciliation
```

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

### Inner loop without GitHub

The public-flake runners above push `main` so Prometheus can evaluate a
`github:` ref, which is the durable publish path. The tight inner loop does
**not** have to depend on GitHub being up: build a **local** checkout and the
local nix daemon ships the derivation closure to Prometheus itself over the
trusted remote-builder SSH path (host-key-authenticated `nix.sshServe`, the
same connection ordinary remote builds use). For example, from a dispatcher
such as `ouranos`:

```sh
# builds on Prometheus over the builder connection; no GitHub round-trip
nix build /path/to/CriomOS-test-cluster#checks.x86_64-linux.vm-mercury \
  --no-link --print-build-logs
```

The dispatch uses the nix daemon's builder identity (the dispatcher's SSH host
key, authorized in Prometheus's `nix.sshServe.keys`), so it needs no per-user
credential. To pre-seed a specific store path outside a build dispatch, an
explicit `nix copy` must run over that same trusted identity (i.e. as the
daemon/root using the host key), since ordinary user keys are not authorized on
the builder's restricted `nix-ssh` account:

```sh
sudo NIX_SSHOPTS="-i /etc/ssh/ssh_host_ed25519_key" \
  nix copy --to ssh-ng://nix-ssh@prometheus.goldragon.criome <store-path>
```

In practice the local-checkout `nix build` above already ships the closure for
you. Keep `git push` as the publish of record; this local-dispatch path is the
availability fallback so an inner iteration is not blocked by GitHub.
