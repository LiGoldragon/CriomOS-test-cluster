# Agent Instructions - CriomOS Test Cluster

You MUST read lore's `AGENTS.md` and the primary workspace
`AGENTS.md` before editing.

## Repo Role

This repository is an independent fixture cluster for CriomOS,
Horizon, and sandboxed Nix regression tests. It is intentionally not
the production cluster. Its purpose is to prove that CriomOS consumes
projected Horizon data without depending on production node names,
secrets, or host facts.

## Rules

- Keep fixtures synthetic. Do not copy production cluster names,
  addresses, passwords, keys, or certificates into this repository.
- Tests are Nix-first. Add constraints as `checks.*` and run them with
  `nix flake check`.
- Prometheus runs use `nix run .#run-on-prometheus`, which pushes
  `main` and evaluates the public GitHub flake inside a transient
  systemd user sandbox.
- Use Nota for cluster input fixtures. Do not add YAML.
- Use `jj` for local history and move the `main` bookmark explicitly
  before pushing.
