# Non-ideal agent notes

## Retired Persona/Upgrade checks are outside current Lojix certification

- **Symptom:** a repository-wide `nix flake check` may evaluate the historical
  `spirit-nspawn-can-build` fixture and reach the retired `persona-spirit`,
  `persona-spirit-v010`, or `upgrade` input graph. Those historical inputs can
  still refer to the retired `LiGoldragon/nota-derive.git` source.
- **Current certification surface:** current Lojix release evidence runs the
  narrow `lojix-deploy-smoke` C6 fixture and `vm-base-home` current
  CriomOS-home witness against the pinned Lojix candidate. Those checks are
  independent of the retired migration graph.
- **Maintenance boundary:** any repair of the retired Persona/Upgrade fixtures,
  old codec sources, or migration inputs is separate repository maintenance;
  do not advance those pins or treat their full-flake evaluation failures as
  Lojix release blockers.
