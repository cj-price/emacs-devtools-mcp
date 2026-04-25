# 031 — Transient dispatcher

**As** the user
**I want** a single `M-x emacs-devtools-mcp` command that opens a transient menu for start/stop, list/kill handles, and run-tests
**So that** I don't have to remember 8 different command names to operate the package.

## INVEST
- **I**: depends only on the server existing; spawn-handle commands gracefully no-op if 020 hasn't landed.
- **N**: which commands appear is open and trivially mutable; the structure is fixed.
- **V**: the "magit-shaped" UX — making the package feel like a first-class Emacs citizen.
- **E**: S (~half day).
- **S**: ~80 lines + tests.
- **T**: transient menus are awkward to test; do an `:fast` test asserting `transient-define-prefix` registered the prefix and the suffix list is non-empty.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006

## Acceptance criteria
- [ ] `(transient-define-prefix emacs-devtools-mcp ()` declared in `lisp/emacs-devtools-mcp.el` (the entry file). Autoloaded.
- [ ] Suffixes:
  - `s s` — `emacs-devtools-mcp-start` (start server)
  - `s k` — `emacs-devtools-mcp-stop` (stop server)
  - `s s` — `emacs-devtools-mcp-restart` (replace if conflicts)
  - `h l` — `emacs-devtools-mcp-list-handles` (opens a tabulated-list buffer)
  - `h k` — `emacs-devtools-mcp-kill-handle` (interactive prompt)
  - `t t` — `emacs-devtools-mcp-run-tests` (calls `make test-fast` in a comint)
  - `c c` — `customize-group emacs-devtools-mcp`
- [ ] Suffixes that depend on later stories (handles → 020) are present but show "not available" if the registry symbol is unbound.
- [ ] Status line in the prefix shows server status (`running on $SOCK` or `stopped`) and number of handles.
- [ ] `M-x emacs-devtools-mcp-mode` is a global minor mode that auto-starts the server on enable, stops on disable.
- [ ] All commands are checkdoc-clean.

## Files touched
- `lisp/emacs-devtools-mcp.el` (extend)
- `test/emacs-devtools-mcp-tests.el` (UX section, `:fast`)

## Test plan
- ERT `:fast`: `(get 'emacs-devtools-mcp 'transient--prefix)` non-nil.
- ERT `:fast`: prefix has at least 6 suffixes.
- ERT `:fast`: minor mode toggle calls start then stop (cl-letf counters).
- Manual: `M-x emacs-devtools-mcp` from a live Emacs renders the menu without errors. (Documented in test plan; no automation.)
