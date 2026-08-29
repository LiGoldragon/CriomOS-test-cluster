# Agent Instructions - CriomOS Test Cluster

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
- Use canonical Datomic for cluster input fixtures. Do not add a legacy
  notation, YAML, or a compatibility reader.
- Use `jj` for local history and move the `main` bookmark explicitly
  before pushing.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## Protos estate status

Protos estate scope: out of scope
Stack: not applicable
Role: operating-system test environment
This is scope metadata, not a stack.
