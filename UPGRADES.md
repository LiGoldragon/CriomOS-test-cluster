# Upgrades

## Unreleased — Horizon 0.5.1 Datomic fixtures

The synthetic cluster proposals moved from legacy Dotos to canonical Datomic
as one atomic migration with Horizon `0.5.1`
(`f8c5808466a47c2fd741cf0b119d73e8ba2add3d`). A one-shot historical typed
decoder recovered each legacy proposal; the current Horizon typed writer
emitted the Datomic source. The migration evidence is retained outside the
product repository.

Consumers must use `clusters/*.datomic` and the pinned current Horizon CLI.
There is no compatibility parser or legacy fixture path.

### CriomOS Chroma owner-chain lock

The direct CriomOS lock now follows published `2ea09dd5625be0ad795ce8cb93f012a6739e1a7e`,
which carries CriomOS-home `0ae8e4953f03bfcd007bf723d7f8547742de9300` and
Chroma `1b626d9dc325459be6c825d0c5a59a7d245d1edd`. This advances only the
owner-published dependency closure; cluster fixtures and independent root
inputs remain unchanged.
