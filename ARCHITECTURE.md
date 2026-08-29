# Architecture

CriomOS-test-cluster is a synthetic regression fixture. Its canonical source
is one typed `ClusterProposal` per `clusters/*.datomic` file.

Horizon 0.5.1 parses that Datomic directly and projects a viewpoint-specific
JSON horizon for every fixture node. The committed files in
`fixtures/horizon/` are those projections. The `projections-match-fieldlab`
check reprojects each fixture through the pinned Horizon CLI and compares it
with its committed JSON, so each test consumes a generated cluster fact rather
than a hand-authored horizon.

There is one parser: Horizon's typed Datomic parser. Legacy fixture syntax and
compatibility decoders do not belong to this repository.
