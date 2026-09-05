# Architecture

CriomOS-test-cluster is a synthetic regression fixture. Its canonical source
is a typed `ClusterDefinition` plus `HorizonConfiguration` in `clusters/`.

The pinned Horizon 0.6.0 typed composer combines those two explicit inputs
into one `HorizonDefinition`; the CLI projects a viewpoint-specific JSON
horizon for every fixture node. The committed files in
`fixtures/horizon/` are those projections. The `projections-match-fieldlab`
check composes and reprojects each fixture through the pinned Horizon CLI and compares it
with its committed JSON, so each test consumes a generated cluster fact rather
than a hand-authored horizon.

There is one parser: Horizon's current typed Datom parser. The migration's
one-shot legacy reader was verification machinery outside this repository;
legacy fixture syntax and compatibility decoders do not belong here.
