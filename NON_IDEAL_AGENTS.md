# Non-ideal agent notes

## Full flake check reaches retired `nota-derive` fixture pins

- **Symptom:** `nix flake check --no-build` stops while evaluating
  `checks.x86_64-linux.spirit-nspawn-can-build`: the locked
  `persona-spirit`, `persona-spirit-v010`, and `upgrade` fixture inputs each
  retain a Cargo lock source for the retired
  `LiGoldragon/nota-derive.git` repository.
- **Current workaround:** run the affected fixture's narrow check directly;
  the Lojix release-safety C6 check is independent and validates through the
  public `LiGoldragon/nota` source.
- **Proper fix:** advance those separate fixture inputs through their ordinary
  review branches to revisions whose Cargo locks resolve both `nota` and
  `nota-derive` from public `LiGoldragon/nota`. Do not add a temporary Git
  redirect, replace a fixed-output hash, or change the Lojix dependency
  topology to bypass the block.
