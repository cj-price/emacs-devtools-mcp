# 023 — Host-vs-spawn parity test suite

**As** the package developer
**I want** parametrized ERTs that run a representative tool against both `{host: t}` and `{spawn: ID}` and assert equal results
**So that** the dispatch routing in 021 doesn't silently diverge between targets — and so future contributors can't break parity without a red test.

## INVEST
- **I**: tests-only; no production code change.
- **N**: which tools to parametrize is open; pick the ones that exercise distinct return shapes.
- **V**: prevents the worst class of bug ("works on host, broken on spawn") from reaching users.
- **E**: M (~1 day).
- **S**: ~150 lines of test code.
- **T**: every assertion is `equal` between two captured results.

## Dependencies
- 021-spawn-target-routing-depends-on-019-006

## Acceptance criteria
- [ ] `ert-deftest` per tool below, each running once with `{host: t}` and once with a fresh-daemon spawn handle, asserting `equal` (modulo expected diffs documented in the test).
- [ ] Parametrized tools: `eval-elisp` (string return), `simulate-keys` (struct return), `face-at` (face return), `buffer-substring` (text return), `list-messages` (list return), `ert-run` (counts).
- [ ] Documented diffs allowed: `duration_ms`, `pid`, `messages_delta` for asynchronous backgrounds (use predicate, not `equal`, for those fields).
- [ ] Test fixtures use `with-temp-buffer` (host) and a buffer pre-created in spawn via a setup form so the input buffer state is identical.
- [ ] `:fresh-daemon` tag so the suite can be selectively run.
- [ ] On any divergence, failure message names exactly which field differs.

## Files touched
- `test/emacs-devtools-mcp-spawn-tests.el` (Parity section)

## Test plan
- This story IS the test plan; the AC is the test.
- Negative regression check: temporarily break `spawn-call` to drop the last form's value → all parity tests turn red.
