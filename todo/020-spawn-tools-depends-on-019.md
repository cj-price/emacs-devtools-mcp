# 020 — Spawn lifecycle tools

**As** an agent
**I want** MCP tools `spawn-emacs`, `attach-emacs`, `list-handles`, `kill-emacs` mapped onto the spawn machinery
**So that** I can manage subordinate Emacsen without bespoke commands per workflow.

## INVEST
- **I**: thin wrappers; depends only on 019.
- **N**: schema field names locked once exposed (snake_case wire keys).
- **V**: until these land, only the package itself can spawn — agents can't.
- **E**: M (~1 day for all 4 tools + tests).
- **S**: ~120 lines + tests.
- **T**: each is a one-line shim around 019; tested via the same fixtures.

## Dependencies
- 019-spawn-machinery-depends-on-005-006

## Acceptance criteria
- [ ] `spawn-emacs(init?, headless?, name?)` (`:fast`, destructive, not idempotent): returns `{handle, server_name, pid, expires_at, headless}`.
- [ ] `attach-emacs(server_name)` (`:fast`, destructive): returns the handle struct as above.
- [ ] `list-handles(cursor?)` (`:fast`, read-only, idempotent): paginated list `[{handle, idle_seconds, expires_at, pid, headless, server_name}, ...]`.
- [ ] `kill-emacs(handle)` (`:fast`, destructive): returns `{killed: true, server_name}` or error envelope `handle_not_found`.
- [ ] Schema for all four declared via `deftool` with snake_case JSON keys.
- [ ] Calling `spawn-emacs` when `emacs-devtools-mcp-spawn-max-handles` (defcustom, default 4) is reached → error envelope `max_handles_reached` with `current_count`. (Reaping logic in 022; this story just enforces the cap.)
- [ ] All four tools work without `target` (they live on the host).

## Files touched
- `lisp/emacs-devtools-mcp-tools-spawn.el` (new — or fold into `-tools-eval.el`'s file if that's small enough; story 019's spawn lib stays separate)
- `test/emacs-devtools-mcp-tests.el` (Spawn section) and `test/emacs-devtools-mcp-spawn-tests.el`

## Test plan
- ERT `:fresh-daemon`: `spawn-emacs` returns a handle; subsequent `list-handles` includes it.
- ERT `:fresh-daemon`: `kill-emacs` removes it; second call → `handle_not_found`.
- ERT `:fresh-daemon`: spawn 5 with cap of 4 → fifth returns `max_handles_reached`.
- ERT: `attach-emacs` against a daemon started by hand outside the package → handle returned.
- ERT: `list-handles` paginates correctly when cap is bumped to 8.
