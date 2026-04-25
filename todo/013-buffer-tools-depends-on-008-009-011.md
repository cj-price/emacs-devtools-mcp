# 013 — Buffer / state tools

**As** an agent
**I want** to enumerate buffers, read a buffer's text, peek at *Messages* and *Warnings*, run ERT, and inspect hooks
**So that** I can answer "what's the state of the editor right now?" questions without writing eval-elisp boilerplate.

## INVEST
- **I**: each tool is independent of the others; bundled here because they share the buffer category and snake_case `list-*` naming convention.
- **N**: filter syntax for `list-buffers` and `list-faces` open (glob vs regex); pick one, document it.
- **V**: the read-only baseline an agent will hit on every task.
- **E**: M (~2 days for all 7 tools).
- **S**: borderline — split into two stories if it grows beyond ~250 lines + tests.
- **T**: every tool is a pure read with deterministic output for fixture buffers.

## Dependencies
- 008-initialize-list-call-ping-depends-on-004-006
- 009-cursor-store-depends-on-008
- 011-output-caps-depends-on-008

## Acceptance criteria
- [ ] `list-buffers(filter?, cursor?)` (`:fast`, read-only): returns `[{name, file, modes (major+minor), modified, size, point, line_count}, ...]` paginated via cursor (009). `filter` is an Emacs regex over buffer names.
- [ ] `buffer-state(buffer)` (`:fast`, read-only): returns `{name, file, major_mode, minor_modes, point, mark, narrowed_to: [start,end] | null, line_count, size, modified, read_only, coding_system}`. Errors with `buffer_not_found` if missing.
- [ ] `buffer-substring(buffer, start, end, with_properties?, max_bytes?)` (`:fast`, read-only): byte-capped (011); returns `{text, truncated, next_offset}`. `with_properties` defaults false. Negative or out-of-range positions clamped, not errored, with `clamped: true` flag.
- [ ] `list-messages(n?, cursor?)` (`:fast`, read-only): tail of `*Messages*`, redacted via 010. `n` defaults to 100. Cursor allows pulling earlier history.
- [ ] `list-warnings(cursor?)` (`:fast`, read-only): scraped from `*Warnings*` buffer; one entry per warning header.
- [ ] `ert-run(selector?)` (`:slow`, destructive): runs ERT in the host (or spawn once 021 lands), returns `{passed, failed, skipped, total, duration_ms, failed_details: [...]}`. Selector is the standard ERT selector string.
- [ ] `describe-hooks(hook?)` (`:fast`, read-only): if `hook` is provided, returns its current value (functions list with locations); if omitted, returns a paginated list of all bound hook variables (symbols ending in `-hook` or `-functions`).
- [ ] Every tool's output flows through 010 redaction and 011 caps.

## Files touched
- `lisp/emacs-devtools-mcp-tools-buffer.el` (new)
- `lisp/emacs-devtools-mcp.el` (require it)
- `test/emacs-devtools-mcp-tests.el` (Buffer section)

## Test plan
- `list-buffers` with regex filter: only matching buffers returned; cursor paginates.
- `buffer-state` for `*scratch*`: returns expected major-mode = `lisp-interaction-mode`.
- `buffer-substring` clamps out-of-range and reports `clamped: true`.
- `buffer-substring` with `with_properties: true` returns serialized text properties.
- `list-messages` returns redacted lines for an `auth-source` log entry.
- `list-warnings` finds a fixture warning emitted via `display-warning`.
- `ert-run` with a selector that matches one passing and one failing test reports correct counts.
- `describe-hooks 'find-file-hook` returns its current functions.
- `describe-hooks` with no arg paginates over hook variables.
