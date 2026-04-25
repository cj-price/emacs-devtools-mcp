# 024 — edebug tools

**As** an agent debugging an elisp function
**I want** to instrument and uninstrument a function for edebug, and capture a backtrace from a form
**So that** I can isolate where a bug happens without round-tripping through the user "press X to enter the debugger".

## INVEST
- **I**: depends on `eval-elisp` so the dispatch + redaction surface is in place.
- **N**: how much edebug state to expose (breakpoints? stops?) is open; v1 is just instrument/uninstrument + capture-backtrace.
- **V**: closes the "reproduce in debugger" debugging loop.
- **E**: M (~1.5 days).
- **S**: ~150 lines + tests.
- **T**: instrumentation is observable via `(get FN 'edebug)`; backtrace is text-asserted.

## Dependencies
- 012-eval-elisp-depends-on-008-010-011

## Acceptance criteria
- [ ] `edebug-instrument(function)` (`:fast`, destructive): wraps `edebug-instrument-function`. Errors → `function_not_found`/`source_not_available`.
- [ ] `edebug-uninstrument(function)` (`:fast`, destructive): wraps `edebug-uninstrument-function` (or `eval-defun` of the original source). Idempotent in effect.
- [ ] `capture-backtrace(form)` (`:slow`, destructive): evaluates the form inside a `condition-case` whose handler captures `backtrace-frames` redacted via 010, returns `{value (if no error), error_type, error_message, backtrace, messages_delta, duration_ms}`.
- [ ] `:slow` (006) wraps the tool body so a runaway form can be preempted.
- [ ] Backtrace is capped at `emacs-devtools-mcp-backtrace-max-frames` (defcustom, default 50) and each frame's args printed with the global `print-level`/`print-length` from 011.
- [ ] When `target.spawn`, instrumentation persists in the subordinate; documented in commentary.
- [ ] All output flows through 010 redaction and 011 caps.

## Files touched
- `lisp/emacs-devtools-mcp-tools-eval.el` (extend)
- `test/emacs-devtools-mcp-tests.el` (Eval section)

## Test plan
- ERT: define a fixture function with `defun`, instrument it, assert `(get 'fixture 'edebug)` non-nil; uninstrument, assert nil.
- ERT: instrument a primitive (built-in C function) → `source_not_available`.
- ERT: `capture-backtrace '(error "boom")` → backtrace contains `error` and the call frame; redaction applied if any frame's arg is an auth-source path.
- ERT: backtrace longer than cap → truncated with `truncated: true`.
- ERT `:fresh-daemon`: instrument in spawn, assert via `eval-elisp` to spawn that `(get 'fn 'edebug)` is set.
