# 001 — Project scaffolding

**As** the package developer
**I want** a buildable, testable, lintable empty package
**So that** every later story lands on a CI-green foundation.

## INVEST
- **I**: no other story depends on artifacts that aren't here.
- **N**: file content is open; layout is fixed.
- **V**: enables every later story (no value standalone).
- **E**: M (~1 day).
- **S**: scaffolding only; no logic.
- **T**: AC is binary — `make all` exits 0 against an empty `lisp/` placeholder.

## Dependencies
- none (`shell.nix` already exists)

## Acceptance criteria
- [ ] `Makefile` with targets: `all`, `lisp`, `test`, `test-fast`, `test-daemon`, `test-gui`, `test-mcp`, `lint`, `manual`, `clean`, `install`. Phony targets declared. Each target documented with one-line `# comment`.
- [ ] `lisp/emacs-devtools-mcp.el` placeholder file: full magit-style header (lexical-binding, SPDX, Package-Requires `(emacs "29.1") (compat "30.1") (transient "0.6.0")`), `(provide 'emacs-devtools-mcp)`, footer.
- [ ] `LICENSE` — full GPL-3.0-or-later text.
- [ ] `CONTRIBUTING.md` — short (<50 lines): how to run tests, how to file an issue, branch convention.
- [ ] `CHANGELOG` — empty header `## Unreleased`.
- [ ] `.gitignore` — `*.elc`, `manual/*.info`, `manual/*.html`, eln cache, `.dir-locals.el?` if it has user-private state, etc.
- [ ] `.dir-locals.el` — `lexical-binding: t` for elisp; fill-column 80; `indent-tabs-mode: nil`.
- [ ] `README.md` — single sentence + `nix-shell --run 'make all'` instruction. Full README is story 033.
- [ ] `manual/emacs-devtools-mcp.texi` — minimal valid texinfo (title, copyright, single chapter "Introduction" with TODO).
- [ ] `nix-shell --run 'make all'` exits 0.
- [ ] `nix-shell --run 'make lint'` exits 0 against the placeholder.

## Files touched
- `Makefile`
- `lisp/emacs-devtools-mcp.el`
- `LICENSE`
- `CONTRIBUTING.md`
- `CHANGELOG`
- `.gitignore`
- `.dir-locals.el`
- `README.md`
- `manual/emacs-devtools-mcp.texi`

## Test plan
- `make all` → exit 0.
- `make lint` → exit 0.
- `make manual` → produces `manual/emacs-devtools-mcp.info`.
- `emacs --batch -L lisp -l emacs-devtools-mcp -f kill-emacs` → exit 0 (autoloads parse, file loads).
