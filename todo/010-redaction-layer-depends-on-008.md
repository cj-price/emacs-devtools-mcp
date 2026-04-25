# 010 — Output redaction layer

**As** the host Emacs user
**I want** lines matching auth/secret patterns stripped from any *Messages*/backtrace surface before they leave the process
**So that** an agent can't inadvertently read auth-source/TRAMP/GPG diagnostics.

## INVEST
- **I**: pure string transformation; no other code depends on it landing first, but 012 (eval-elisp) and 013 (buffer tools) need it.
- **N**: regex set is open; the contract (some redaction always applied to *Messages*) is fixed.
- **V**: closes a real info-leak channel.
- **E**: S.
- **S**: ~50 lines + tests.
- **T**: regex transformation; trivial.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006

## Acceptance criteria
- [ ] `emacs-devtools-mcp-rpc-redact STRING` returns a redacted copy.
- [ ] Default regex set strips lines matching: `^auth-source[:-]`, `^Auth-source: `, `^epg[:-]`, `^Tramp: `, `^Saving file .* (with .* keys)`.
- [ ] Defcustom `emacs-devtools-mcp-redact-extra-regexps` appended.
- [ ] Defcustom `emacs-devtools-mcp-redact-disabled-p` (default nil) — when t, no redaction (developer escape hatch).
- [ ] Replaced lines become `[redacted: pattern-name]` so the count of lines is preserved (line-number references in error messages still align).
- [ ] Applied automatically to *Messages* delta and backtrace data captured by `eval-elisp`, `capture-backtrace`, `init-lint`, `startup-profile`.
- [ ] Property test: redacting an already-redacted string is a no-op (idempotent).

## Files touched
- `lisp/emacs-devtools-mcp-rpc.el` (or split into `-redact.el` if it grows)
- `test/emacs-devtools-mcp-tests.el` (Redaction section)

## Test plan
- Each default regex: positive + negative case.
- Custom regex via defcustom: applied.
- Disabled flag: passes through unchanged.
- Idempotent property test (`propcheck`).
- Multi-line input with mixed redactable / non-redactable lines.
