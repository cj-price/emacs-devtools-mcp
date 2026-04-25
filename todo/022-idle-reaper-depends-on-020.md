# 022 — Idle reaper and `max-handles` cap

**As** the host Emacs user
**I want** spawned subordinate Emacsen to die after I stop using them
**So that** I don't accumulate ghost daemons after a long debugging session.

## INVEST
- **I**: depends on the spawn tools so handles have an observable `last-used-at`.
- **N**: idle threshold default (30 min) negotiable; cap default (4) negotiable.
- **V**: the difference between a hygienic tool and a memory leak.
- **E**: S (~half day).
- **S**: ~50 lines + tests.
- **T**: time-mocked tests prove the reaper logic.

## Dependencies
- 020-spawn-tools-depends-on-019

## Acceptance criteria
- [ ] Defcustom `emacs-devtools-mcp-spawn-idle-timeout` (default 1800 seconds = 30 min).
- [ ] Defcustom `emacs-devtools-mcp-spawn-reap-interval` (default 60 seconds).
- [ ] Defcustom `emacs-devtools-mcp-spawn-max-handles` (default 4) — already referenced in 020; defined here authoritatively.
- [ ] An idle timer (`run-with-timer`) ticks the reaper. Per-handle `last-used-at` updated by `spawn-call`.
- [ ] On reap, killed handles are dropped from the registry with an info-level log line.
- [ ] When `max-handles` is reached, the oldest *idle* handle is reaped to make room for a new spawn IF idle ≥ 60 s; otherwise the new spawn fails with `max_handles_reached` (matching 020).
- [ ] `kill-emacs-hook` cancels the timer and reaps everyone.
- [ ] `list-handles` (020) reports `expires_at` computed from `last-used-at + idle-timeout`.

## Files touched
- `lisp/emacs-devtools-mcp-spawn.el` (extend)
- `test/emacs-devtools-mcp-spawn-tests.el`

## Test plan
- Spawn a handle, advance `current-time` past the idle threshold via `cl-letf`, run the reaper → handle is gone.
- Spawn a handle, call `spawn-call` to bump `last-used-at`, then advance time slightly less than the threshold → handle survives.
- Cap at 2; spawn 2 idle for 90 s; spawn third → oldest reaped, third created.
- Cap at 2; spawn 2 fresh; spawn third → `max_handles_reached`.
- `kill-emacs-hook` test (using `unwind-protect`) reaps all live handles.
