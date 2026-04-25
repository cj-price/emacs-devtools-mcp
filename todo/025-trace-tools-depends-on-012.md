# 025 — trace tools

**As** an agent watching a function for behavior
**I want** to enable `trace-function`, fetch its log, and disable it
**So that** I can confirm a function fires when I expect it to and inspect its arguments without modifying the caller.

## INVEST
- **I**: parallel to 024; both depend on the eval surface but are otherwise independent.
- **N**: log buffer naming (`*trace-output*` is built-in) and the cursor pagination shape over it.
- **V**: covers the "is this hook even running?" debugging case which is high-frequency.
- **E**: M (~1 day).
- **S**: ~120 lines + tests.
- **T**: assertion is "log buffer contains call frames" with deterministic input.

## Dependencies
- 012-eval-elisp-depends-on-008-010-011

## Acceptance criteria
- [ ] `trace-function(fn, buffer?)` (`:fast`, destructive): wraps `trace-function-foreground` (or `trace-function-background` if `buffer` provided). Errors → `function_not_found`.
- [ ] `untrace-function(fn)` (`:fast`, destructive): wraps `untrace-function`; idempotent in effect.
- [ ] `trace-log(fn, cursor?)` (`:fast`, read-only): returns lines from `*trace-output*` filtered to the named function, paginated via 009 cursor. Lines redacted via 010, capped via 011.
- [ ] When `target.spawn`, the trace lives in the subordinate's `*trace-output*`; `trace-log` reads from there via the spawn dispatch.
- [ ] Trace output is parsed into `[{call_or_return, depth, fn, args, value, time}, ...]` rather than raw strings; cap-friendly + agent-friendly.

## Files touched
- `lisp/emacs-devtools-mcp-tools-eval.el` (extend) or split into `-tools-trace.el` if the eval file exceeds ~300 lines
- `test/emacs-devtools-mcp-tests.el` (Eval/Trace section)

## Test plan
- ERT: `trace-function 'identity`; call `(identity 42)` via `eval-elisp`; `trace-log 'identity` returns one call + one return frame.
- ERT: `untrace-function 'identity` then `(identity 42)` → `trace-log` returns nothing new.
- ERT: tracing a function whose args contain auth-source data → log entries redacted.
- ERT: large trace → cursor pagination returns subsequent pages.
- ERT `:fresh-daemon`: trace in spawn, retrieve log via `target.spawn`.
