# 012 — `eval-elisp` tool

**As** an agent
**I want** to evaluate an arbitrary Elisp form in the host or a spawn target and get back the printed value plus side-effect surface
**So that** I can introspect or manipulate Emacs state without writing a one-off tool for every shape of question.

## INVEST
- **I**: depends on the registry, redaction, and caps; spawn routing arrives in 021.
- **N**: exact shape of the returned struct (value, stdout, messages_delta, error, duration_ms) is open until first agent uses it.
- **V**: the swiss-army-knife tool — unblocks debugging workflows immediately.
- **E**: M (~1.5 days).
- **S**: ~120 lines + tests.
- **T**: round-trip + side-effect capture is straightforward to assert.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006
- 010-redaction-layer-depends-on-008
- 011-output-caps-depends-on-008

## Acceptance criteria
- [ ] Tool: `eval-elisp` (`:cost :slow`, destructive, not idempotent, not read-only).
- [ ] Schema: `form` (string, required), `print_level` (integer | null), `print_length` (integer | null), `target` (oneOf host/spawn — host-only until 021 lands).
- [ ] `form` is parsed via `(let ((read-eval nil)) (read-from-string FORM))` to refuse `#.` reader-macro injection.
- [ ] Returns content blocks containing: `value` (prin1 of the result, capped), `stdout` (string from `standard-output`), `messages_delta` (lines added to *Messages* during the call, redacted via 010), `duration_ms`.
- [ ] On signaled error: returns `isError: true` with `error_type` (the symbol), `error_message`, `backtrace` (list of frames, redacted, capped).
- [ ] `:slow` wrapping (from 006) is honored — long evals can be preempted by user keystrokes via `while-no-input`.
- [ ] Print width: `print-level`/`print-length` from request override the server defaults from 011 for this call only.
- [ ] *Messages* delta computed by snapshotting `(buffer-size (get-buffer "*Messages*"))` before/after — no filter races.
- [ ] All output flows through 010 redaction and 011 caps.

## Files touched
- `lisp/emacs-devtools-mcp-tools-eval.el` (new file, `:cost :slow` handler)
- `lisp/emacs-devtools-mcp.el` (require it)
- `test/emacs-devtools-mcp-tests.el` (Eval section)

## Test plan
- ERT: `(+ 1 2)` → value `"3"`.
- ERT: `(message "hi")` → `messages_delta` contains `"hi"`.
- ERT: `(princ "x")` → `stdout` contains `"x"`.
- ERT: `(error "boom")` → `isError`, `error_type=error`, message present.
- ERT: form containing `#.(delete-file "/tmp/x")` → refused at parse.
- ERT: a 60-second `(sleep-for 60)` form → user keystroke (simulated via `(throw 'while-no-input nil)`) preempts cleanly.
- ERT: `auth-source-search` output appears in `messages_delta` redacted.
- ERT: `print_level` of 1 truncates a nested form's printed value.
