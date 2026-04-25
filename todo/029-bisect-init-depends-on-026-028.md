# 029 — `bisect-init` tool

**As** the user
**I want** the agent to bisect my init.el to find the smallest range of forms that triggers a regression
**So that** "Emacs got slow / errored / mis-renders after my last reorganize" turns into a concrete line range.

## INVEST
- **I**: depends on lint surface (026) for parsing top-level forms reliably and on the persistent pipe (028) for amortized iteration cost.
- **N**: predicate signature is open; pick "elisp form returning non-nil = bad" because everything else is harder to express on the wire.
- **V**: the tool that turns a "bisect by hand" afternoon into a 30-second agent action.
- **E**: M (~2 days).
- **S**: ~200 lines + tests; pushes against L if the predicate sandbox fights us.
- **T**: against a fixture init with a known bad form at line N, the tool returns a bracket containing N.

## Dependencies
- 026-init-lint-depends-on-019
- 028-persistent-subordinate-pipe-depends-on-019

## Acceptance criteria
- [ ] Tool: `bisect-init(file, predicate)` (`:cost :slow`, destructive).
- [ ] `file` validated against allowlist (019); `predicate` is a string of an elisp form that returns non-nil to indicate "bad".
- [ ] Reads the init file as a list of top-level forms via `(read FROM-BUFFER)` in a loop; preserves source line numbers per form.
- [ ] Opens a persistent pipe (028) to a fresh `-Q` daemon. Per probe: erases all prior forms in the daemon, evaluates the candidate subset of forms, then evaluates the predicate; predicate result drives bisect direction.
- [ ] Bisects with a binary-search-by-prefix-length over top-level form indices. Returns `{good_prefix_len, bad_prefix_len, suspected_range: [{start_line, end_line, source}], probes_run, total_duration_ms}`.
- [ ] Predicate evaluation uses `(let ((read-eval nil)) (read ...))` to refuse `#.` injection.
- [ ] On predicate crash (vs returning false), surfaces as `predicate_error` envelope with the trapped error — distinct from "predicate said false".
- [ ] Pipe closed in `unwind-protect`.
- [ ] Cap on probe count: defcustom `emacs-devtools-mcp-bisect-init-max-probes` (default 32). Beyond cap, returns the current bracket as `partial: true`.
- [ ] Output redacted (010) + capped (011).

## Files touched
- `lisp/emacs-devtools-mcp-tools-init.el` (extend)
- `test/emacs-devtools-mcp-tests.el` (Init section)

## Test plan
- ERT `:fresh-daemon`: fixture init with a `(setq foo (/ 1 0))` at known line; predicate `(condition-case _ (progn (load init-file) nil) (error t))` → bisect returns range bracketing that line.
- ERT `:fresh-daemon`: predicate that always returns t → returns `bad_prefix_len = 0` (broken from the start).
- ERT `:fresh-daemon`: predicate that always returns nil → returns `good_prefix_len = total` (no bracket found).
- ERT `:fresh-daemon`: predicate with `#.(delete-file ...)` → refused at parse.
- ERT `:fresh-daemon`: probe-count cap reached → `partial: true` with the current bracket.
- ERT `:fresh-daemon`: pipe survives ≥ 16 probes without restart.
