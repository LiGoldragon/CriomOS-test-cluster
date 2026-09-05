# Upgrades

## Unreleased — Horizon 0.6 typed Horizon definitions

The synthetic cluster proposals moved from legacy Dotos to current Datom as
one atomic migration with Horizon `0.6.0`
(`05879e7c1e5f637f78fbe26234b95213c77c59bc`). A one-shot historical typed
reader recovered each proposal; the current typed writer emitted a
`ClusterDefinition`, which the explicit `HorizonConfiguration` composes into
one `HorizonDefinition`. The migration evidence is retained outside the
product repository.

Consumers must use the composed `horizon-definition.datom` child from the
generic compositor output directory and the pinned current Horizon CLI. There
is no compatibility parser or legacy fixture path.

### CriomOS Chroma owner-chain lock

The direct CriomOS lock now follows published `2ea09dd5625be0ad795ce8cb93f012a6739e1a7e`,
which carries CriomOS-home `0ae8e4953f03bfcd007bf723d7f8547742de9300` and
Chroma `1b626d9dc325459be6c825d0c5a59a7d245d1edd`. This advances only the
owner-published dependency closure; cluster fixtures and independent root
inputs remain unchanged.
