# 033 — README quickstart + transcript

**As** a new user landing on the repo
**I want** a README that gets me from clone → working `M-x emacs-devtools-mcp` + agent transcript in under 5 minutes
**So that** I can decide in 60 seconds whether this package is worth installing.

## INVEST
- **I**: depends on the dispatcher (031) so the quickstart can point at it, and on a working ping (008) so the transcript is real.
- **N**: tone, screenshot count, transcript verbosity all open.
- **V**: the README is the conversion surface — every contributor first impression flows through it.
- **E**: S (~half day of writing, plus capturing the transcript).
- **S**: ~150 lines of markdown.
- **T**: link checker passes; transcript is reproducible.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006
- 031-transient-dispatcher-depends-on-008

## Acceptance criteria
- [ ] `README.md` sections, in order:
  1. **What is this** — one paragraph, "chrome-devtools-mcp for Emacs".
  2. **Quickstart** — clone, `nix-shell --run 'make all'`, register in `.mcp.json` (point at `bin/emacs-devtools-mcp`), `M-x emacs-devtools-mcp` → start, then a Claude Code transcript: ask "what's bound to C-x C-f?" → `where-is` → answer.
  3. **Architecture** — link to manual; one-paragraph summary mirroring the plan's diagram.
  4. **Tool catalog** — table of every tool with `:cost`, annotations, one-line description, link to the manual node.
  5. **Customization highlights** — 5 most-likely-to-tweak defcustoms (`max-handles`, `idle-timeout`, `max-response-bytes`, `init-allowlist`, `redact-extra-regexps`).
  6. **Security** — bullet summary: SO_PEERCRED + token + XDG_RUNTIME_DIR + read-eval=nil + allowlist.
  7. **Status / compatibility** — Emacs 29.1+, tested on pgtk/Wayland and Xvfb headless.
  8. **Contributing** — link to CONTRIBUTING.md (001).
  9. **License** — GPL-3.0-or-later, link to LICENSE (001).
- [ ] One screenshot or asciinema of the agent transcript, stored under `manual/images/`.
- [ ] Badges: CI status, Emacs version support.
- [ ] Every link resolves (CI step: `lychee` or equivalent).
- [ ] No marketing fluff — magit-style direct prose.

## Files touched
- `README.md` (final form)
- `manual/images/quickstart.png` or `manual/images/quickstart.cast`
- `.github/workflows/ci.yml` (add link check, optional)

## Test plan
- Manual: follow the README on a clean machine inside `nix-shell`; reach a working transcript without touching anything outside what's documented.
- Link check: all internal and external links resolve.
- Visual: badges render, screenshot is current, no broken markdown tables.
