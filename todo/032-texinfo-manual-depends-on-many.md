# 032 — Texinfo manual

**As** a contributor or sophisticated user
**I want** a real Emacs-installed `info` manual covering the package
**So that** `(info "emacs-devtools-mcp")` opens a usable reference, not a 404.

## INVEST
- **I**: depends on the tool surface being mostly stable; written last to avoid churn.
- **N**: section ordering open; "Architecture / Tools / Customization / Troubleshooting" works.
- **V**: required for ELPA-grade publishability and serious users; not load-bearing for v0.1 daily use but a magit-grade quality expectation.
- **E**: M (~2 days of careful prose, not coding).
- **S**: borderline — if it grows past 600 lines split into per-tool nodes already covered by the structure.
- **T**: `make manual` builds; index lookups resolve.

## Dependencies
- 013-buffer-tools-depends-on-008-009-011
- 015-simulate-keys-depends-on-014
- 018-frame-and-face-tools-depends-on-017
- 024-edebug-tools-depends-on-012
- 025-trace-tools-depends-on-012
- 029-bisect-init-depends-on-026-028

## Acceptance criteria
- [ ] `manual/emacs-devtools-mcp.texi` builds cleanly under `makeinfo` (no warnings).
- [ ] Top-level nodes: Introduction, Installation, Architecture, Tools, Customization, Troubleshooting, Index.
- [ ] Tools node has a sub-node per category (Eval, Buffer, Keys, GUI, Spawn, Debug, Init).
- [ ] Each tool's sub-node has: one-line summary, schema (snake_case), example call (JSON), example response, error envelope shape if applicable.
- [ ] Customization node lists every `defcustom` from every story with default + brief explanation.
- [ ] Troubleshooting node covers: `XDG_RUNTIME_DIR` unset, stale socket, screenshot backend `:unsupported`, spawn `path_not_allowed`, `payload_too_large`.
- [ ] Index entries: every public symbol, every defcustom, every error envelope code.
- [ ] `make manual` is in the default `make all` target (already declared in 001).
- [ ] Optional: `manual/dir` snippet for `install-info`.

## Files touched
- `manual/emacs-devtools-mcp.texi`
- `Makefile` (already has `manual` target from 001; verify it's in `all`)

## Test plan
- `nix-shell --run 'make manual'` exits 0 with no warnings.
- Open the produced `.info` in Emacs; navigate via `i` to a known index entry.
- Tamper test: introduce an undefined `@xref` → `make manual` fails loudly.
