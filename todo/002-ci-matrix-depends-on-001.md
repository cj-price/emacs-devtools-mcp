# 002 — CI matrix

**As** the package developer
**I want** GitHub Actions running `make all` on Emacs 29.1 / 29.4 / 30.1 for every push and PR
**So that** regressions on supported floors are caught before merge.

## INVEST
- **I**: only depends on 001's `Makefile`.
- **N**: matrix versions and runner OS are negotiable.
- **V**: enforces the build/test/lint contract on every change.
- **E**: S (~half day).
- **S**: one workflow file.
- **T**: a deliberate breakage in a PR fails the workflow.

## Dependencies
- 001-project-scaffolding

## Acceptance criteria
- [ ] `.github/workflows/ci.yml` runs on push to any branch and on `pull_request`.
- [ ] Matrix: `emacs-version: [29.1, 29.4, 30.1]` on `ubuntu-latest`.
- [ ] Uses `purcell/setup-emacs` (or equivalent) to install the matrix Emacs.
- [ ] Installs `xvfb` and `socat` via apt.
- [ ] Installs package deps (`compat`, `transient`) into a per-job package dir.
- [ ] Runs `make all` (lisp + test + lint + manual).
- [ ] Runs `make test-mcp` if the target exists (graceful skip pre-story 030).
- [ ] A PR that introduces a `byte-compile-warning` causes the job to fail.
- [ ] Build artifacts (info file) uploaded on success for the latest matrix cell.

## Files touched
- `.github/workflows/ci.yml`

## Test plan
- Push a branch with an intentional checkdoc warning → CI red.
- Revert → CI green.
- Confirm all 3 matrix cells run.
