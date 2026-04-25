# 018 — Frame and face tools

**As** an agent
**I want** to introspect frame structure, the face at a position, the definition of a face by name, the list of faces, and color contrast
**So that** I can answer "is this rendering correctly?" without round-tripping through screenshots for every check.

## INVEST
- **I**: bundled because they share the GUI category and similar shapes.
- **N**: `get-frame-tree` depth/format open; pick a flat list with parent refs to keep cap-friendly.
- **V**: most modeline / theme questions are answered by `face-at` + `color-contrast` without a screenshot.
- **E**: M (~1.5 days for all 4 tools — `color-contrast` is property-test bait).
- **S**: ~200 lines + tests.
- **T**: every tool is deterministic given a frame fixture; `color-contrast` is pure math.

## Dependencies
- 017-screenshot-frame-depends-on-016

## Acceptance criteria
- [ ] `get-frame-tree(frame?)` (`:fast`, read-only): returns `[{frame_name, parent (or null), windows: [{window_id, buffer, point, dimensions}]}, ...]` for the requested frame, or all frames if omitted.
- [ ] `face-at(buffer, line, col)` (`:fast`, read-only): returns `{face_names, foreground (hex), background (hex), inherited_from, char}`. `line` 1-based, `col` 0-based (matches Emacs IDE coordinates the project uses).
- [ ] `describe-face(name)` (`:fast`, read-only): returns the face spec as resolved on the active frame: `{foreground, background, weight, slant, underline, overline, strike_through, box, height, inherit}`.
- [ ] `list-faces(filter?, cursor?)` (`:fast`, read-only): paginated list of `face-list`, each entry with `{name, foreground, background, doc_first_line}`. `filter` is a regex.
- [ ] `color-contrast(fg, bg)` (`:fast`, read-only, idempotent): WCAG 2.1 contrast ratio; accepts hex (`#RRGGBB`) or named colors via `color-name-to-rgb`. Returns `{ratio, passes_aa_normal, passes_aa_large, passes_aaa_normal, passes_aaa_large}`.
- [ ] All four tools work on host; spawn routing in 021.
- [ ] `face-at` errors with `out_of_range` (not signaled error) for line/col beyond buffer.

## Files touched
- `lisp/emacs-devtools-mcp-tools-gui.el` (extend)
- `test/emacs-devtools-mcp-tests.el` (GUI section)

## Test plan
- ERT: `get-frame-tree` against a 2-frame test setup → both frames listed.
- ERT: `face-at` on a fixture buffer with a known overlay face at column 0 → returns the expected face name + hex.
- ERT: `describe-face 'mode-line` returns a non-empty foreground on the default theme.
- ERT: `list-faces "^magit-"` returns only matching faces.
- Property test (`propcheck`): `color-contrast` is symmetric (`(ratio fg bg) = (ratio bg fg)`).
- ERT: `color-contrast "#000" "#fff"` → ratio 21.0; passes all four WCAG checks.
- ERT: `face-at` with col beyond line length → `out_of_range`.
