# 028 — Persistent subordinate pipe

**As** `bisect-init` (and any future spawn-heavy tool)
**I want** to amortize the spawn-and-load cost by sending many forms to a single long-lived subordinate
**So that** a 12-iteration bisect doesn't pay 12 × cold-start.

## INVEST
- **I**: depends only on spawn machinery; new utility, no callers until 029.
- **N**: API shape — channel object vs handle-flag — open. Channel object is cleaner.
- **V**: makes 029 (`bisect-init`) feasible at the user-promised latency.
- **E**: M (~1 day).
- **S**: ~150 lines + tests.
- **T**: round-trip latency measured on a tight loop.

## Dependencies
- 019-spawn-machinery-depends-on-005-006

## Acceptance criteria
- [ ] `(emacs-devtools-mcp-spawn-pipe-open &key init headless)`: spawns a daemon and returns a channel struct `(:server-name :process :pid :inbox-buffer)`.
- [ ] `(emacs-devtools-mcp-spawn-pipe-call CHANNEL FORM)`: serializes via `prin1-to-string`, sends via `emacsclient -s NAME --eval STRING`, parses result with `(let ((read-eval nil)) (read ...))` — same contract as `spawn-call` (019) but reuses the daemon.
- [ ] `(emacs-devtools-mcp-spawn-pipe-close CHANNEL)`: kills the daemon (same shutdown path as `spawn-kill` in 019).
- [ ] Channel registered with the same idle reaper (022) so a crashed bisect doesn't leak.
- [ ] Median round-trip latency for `(emacs-devtools-mcp-spawn-pipe-call ch '(+ 1 2))` is ≤ 50 ms on a warm cache (asserted in a `:fresh-daemon` test as a soft check, not strict).
- [ ] Errors from the subordinate (signaled errors during eval) come back as a tagged structure so `bisect-init` can distinguish "predicate said false" from "predicate crashed".

## Files touched
- `lisp/emacs-devtools-mcp-spawn.el` (extend)
- `test/emacs-devtools-mcp-spawn-tests.el`

## Test plan
- ERT `:fresh-daemon`: open pipe, call 100 trivial forms, all return correctly.
- ERT `:fresh-daemon`: open pipe, send a form that signals → tagged-error result, channel still alive.
- ERT `:fresh-daemon`: open pipe, kill the underlying daemon out-of-band → next call returns `pipe_dead`.
- ERT `:fresh-daemon`: idle threshold reached → reaper kills the channel; documented behavior so 029 knows to re-open.
- Soft latency check (skipped if CI is slow): warm round-trip ≤ 50 ms.
