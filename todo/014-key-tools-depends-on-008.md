# 014 — Read-only key tools

**As** an agent debugging a keybind question
**I want** to ask "where is X bound?", "what does this key sequence do?", "show me this keymap", and "trace the translation"
**So that** I can diagnose key conflicts and translation rules without scraping `C-h k` output.

## INVEST
- **I**: pure introspection; no shared state between the four tools.
- **N**: keymap addressing — symbol vs derived-from-mode — open until first agent uses it; default both.
- **V**: covers the common "why isn't my keybind working?" loop.
- **E**: M (~1.5 days for all 4 tools).
- **S**: ~200 lines + tests.
- **T**: each tool is a pure function over Emacs state; fixture-driven.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006

## Acceptance criteria
- [ ] `where-is(command, keymap?)` (`:fast`, read-only): wraps `where-is-internal`; returns `[{keys, keymap_name}, ...]`. `keymap` accepts a symbol like `'global-map` or `'magit-status-mode-map`. Default: search all active keymaps.
- [ ] `lookup-key(keys, keymap?, accept_default?)` (`:fast`, read-only): `keys` is a string in `kbd` syntax. Returns `{command_symbol, command_doc_first_line, source_keymap}` or `{undefined: true}`.
- [ ] `describe-keymap(keymap_or_mode, prefix?, cursor?)` (`:fast`, read-only): flattens a keymap into `[{keys, command, doc_first_line}, ...]`, paginated via cursor. `keymap_or_mode` accepts either a keymap variable name or a mode symbol (in which case it resolves `MODE-map`).
- [ ] `key-translation-trace(keys)` (`:fast`, read-only): runs through `input-decode-map`, `local-function-key-map`, `key-translation-map` and returns the chain of translations applied (or empty if pass-through).
- [ ] All four tools handle non-existent keymap symbols with `keymap_not_found` error.
- [ ] All four tools work against host Emacs; spawn routing arrives in 021.

## Files touched
- `lisp/emacs-devtools-mcp-tools-keys.el` (new)
- `lisp/emacs-devtools-mcp.el` (require it)
- `test/emacs-devtools-mcp-tests.el` (Keys section)

## Test plan
- `where-is 'find-file` → at least `["C-x C-f"]`.
- `where-is 'magit-status` against `'magit-status-mode-map` → returns nothing if magit not loaded; lookup elsewhere fine.
- `lookup-key "C-x C-f"` → `find-file`.
- `lookup-key "C-x C-q"` → `read-only-mode` or `undefined` depending on Emacs version; assertion is "non-error response".
- `describe-keymap 'special-mode-map` → flattened bindings; cursor pagination over a large keymap.
- `key-translation-trace "<f1>"` returns the help-event mapping (if active) or empty.
- All four tools with a bogus keymap symbol → `keymap_not_found`.
