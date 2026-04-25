# 027 — `startup-profile` tool

**As** the user
**I want** the agent to load my init.el under the elisp profiler and return a flame-friendly summary
**So that** I can find the slowest top-level forms without manual profiler dance.

## INVEST
- **I**: parallel to 026; depends on spawn.
- **N**: report shape (top-N by cumulative ms vs full tree) open; pick top-N + total per top-level form.
- **V**: directly answers "why is my Emacs startup slow?" — high user value.
- **E**: M (~1 day).
- **S**: ~150 lines + tests.
- **T**: against a fixture init with `(sleep-for 0.5)`, the tool reports >400 ms attributed to that line.

## Dependencies
- 019-spawn-machinery-depends-on-005-006

## Acceptance criteria
- [ ] Tool: `startup-profile(file?)` (`:cost :slow`, destructive).
- [ ] `file` defaults to `user-init-file`; allowlist-validated (019).
- [ ] Spawns a fresh `-Q` daemon, calls `(profiler-start 'cpu)`, loads the init via `load`, then `(profiler-stop)` always under `unwind-protect`.
- [ ] Returns `{total_ms, top_n: [{function, self_ms, cumulative_ms, calls}, ...]}` where `top_n` is sorted by cumulative ms; default N=20, configurable via `emacs-devtools-mcp-startup-profile-top-n` defcustom.
- [ ] Subordinate killed on completion (success or failure).
- [ ] Output redacted + capped.
- [ ] Per-call sampling rate: defcustom `emacs-devtools-mcp-startup-profile-sampling-interval` (default 1000000 ns = 1 ms; mirrors `profiler-sampling-interval`).

## Files touched
- `lisp/emacs-devtools-mcp-tools-init.el` (extend)
- `test/emacs-devtools-mcp-tests.el` (Init section)

## Test plan
- ERT `:fresh-daemon`: fixture init with `(sleep-for 0.5)` → returns total_ms ≥ 400 with that fn or its caller in top-N.
- ERT `:fresh-daemon`: clean init → returns small total_ms, top-N is empty or contains only built-ins.
- ERT: init outside allowlist → `path_not_allowed`.
- ERT: profiler is always stopped — verify by mocking `load` to error and asserting `profiler-stop` was called (cl-letf advice counter).
- ERT: subordinate is killed even on error.
