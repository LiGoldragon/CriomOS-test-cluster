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
