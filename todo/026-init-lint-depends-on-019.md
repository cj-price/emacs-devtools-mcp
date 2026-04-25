# 026 — `init-lint` tool

**As** the user
**I want** the agent to run a lint pass over my init.el (or any allowed init) and report warnings
**So that** I can catch obsolete options, missing requires, and bad customizations without booting Emacs by hand.

## INVEST
- **I**: depends on spawn so the lint runs in a fresh process.
- **N**: which checks to bundle (byte-compile, checkdoc, package-lint, custom missing-requires) is open; pick byte-compile + a checker for `obsolete-defcustom` to keep v1 small.
- **V**: high signal/effort ratio for the user's primary debugging surface (their own init).
- **E**: S (~half day with spawn already in place).
- **S**: ~80 lines + tests.
- **T**: against a fixture init.el with seeded warnings, the tool lists them.

## Dependencies
- 019-spawn-machinery-depends-on-005-006

## Acceptance criteria
- [ ] Tool: `init-lint(file?)` (`:cost :slow`, read-only).
- [ ] `file` defaults to the user's current init file (`user-init-file` resolved). Validated against `emacs-devtools-mcp-init-allowlist` (019).
- [ ] Spawns a fresh `-Q` daemon; loads `cl-lib`; calls `byte-compile-file` on the init under a `with-temp-buffer` redirected stderr; collects warnings.
- [ ] Returns `[{file, line, severity ("warning"/"error"), message}, ...]`.
- [ ] Output redacted (010), capped (011).
- [ ] Subordinate is killed on completion (`unwind-protect`).
- [ ] On predicate-style use (story 029 calls `init-lint` style), a non-zero warning count is *not* an error envelope — warnings are data.

## Files touched
- `lisp/emacs-devtools-mcp-tools-init.el` (new)
- `test/emacs-devtools-mcp-tests.el` (Init section)

## Test plan
- ERT `:fresh-daemon`: fixture init.el with `(setq foo 'bar)` referencing an unbound variable → tool reports a warning at the right line.
- ERT `:fresh-daemon`: clean init.el → empty warnings list.
- ERT: init outside allowlist → `path_not_allowed` error envelope.
- ERT: byte-compile error in init.el → severity "error" entry.
