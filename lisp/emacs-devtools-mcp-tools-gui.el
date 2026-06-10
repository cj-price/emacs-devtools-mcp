;;; emacs-devtools-mcp-tools-gui.el --- GUI inspection tools  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  cj-price
;; Homepage: https://github.com/cj-price/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.4
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Six tools for inspecting frames, windows, faces, and rendered
;; pixels:
;;   `color-contrast'    -- WCAG contrast ratio between two colors.
;;   `face-at'           -- the face symbol(s) at a buffer position.
;;   `describe-face'     -- inheritance-resolved attribute dump for a face.
;;   `list-faces'        -- paginated face list, optionally regex-filtered.
;;   `get-frame-tree'    -- frames -> windows -> buffers tree.
;;   `screenshot-frame'  -- PNG export of a frame as an MCP image block.
;;
;; The screenshot path runs `x-export-frames' on the host; the
;; backend probe is lazy and caches success.  In batch mode (no
;; display) the tool returns a structured error rather than crashing.
;; `x-export-frames' is the only backend; a daemon that needs a
;; screenshot-capable display can use `spawn_emacs' with
;; `display_mode: "xvfb-run"'.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'color)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-spawn)

;; `x-export-frames' is defined in C (xfns.c) only when Emacs is built
;; with X/PGTK/NS support.  Tell the byte compiler so a no-X build can
;; still byte-compile this file; the runtime backend probe gates the
;; actual call.
(declare-function x-export-frames "xfns" (&optional frames type))

(defcustom emacs-devtools-mcp-faces-page-size 100
  "Default page size for `list-faces'."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-screenshot-max-pixels (cons 2560 1600)
  "Soft cap `(WIDTH . HEIGHT)' for screenshots before downscale.
The pair's product (default 4 096 000) is the actual cap; the
shape is two numbers so the error message can quote a recognizable
resolution.  4.1 MP comfortably covers a HiDPI single-monitor
frame (e.g. 1692x1350 = 2.28 MP, 2880x1800 = 5.18 MP triggers
the cap deliberately).  Lower this for bandwidth-sensitive
agents; raise it for very large displays.

The cap is enforced by refusing to export frames whose pixel
dimensions exceed this product; there is no downscaling -- a
too-large frame returns a structured error naming the cap."
  :type '(cons natnum natnum)
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defvar emacs-devtools-mcp-tools-gui--host-backend nil
  "Cached symbol describing how host screenshots are produced.
Possible values:
  nil               -- not yet probed, or no working backend found
                       on the most recent probe,
  `x-export-frames' -- the built-in works on this Emacs build.
Only success is cached: a probe that finds no graphical frame
\(batch mode, daemon before its first GUI client frame) reports
`unavailable' for that call but leaves this nil, so the next
`screenshot-frame' re-probes.  A daemon user who opens a GUI
frame after a failed screenshot can simply retry.")

;;;; Pure runtime helpers (run on the host or a subordinate via spawn-call).

(defun emacs-devtools-mcp-tools-gui--bool (x)
  "Return t when X is non-nil, otherwise `:json-false'.
The wire mapping wants explicit booleans, not nil-as-null."
  (if x t :json-false))

(defun emacs-devtools-mcp-tools-gui--linearize (channel)
  "Return CHANNEL (an sRGB float in [0,1]) converted to linear-light.
Implements the WCAG 2.x sRGB-to-linear transfer function."
  (if (<= channel 0.03928)
      (/ channel 12.92)
    (expt (/ (+ channel 0.055) 1.055) 2.4)))

(defun emacs-devtools-mcp-tools-gui--luminance (rgb)
  "Return the WCAG relative luminance of RGB (a list of three sRGB floats)."
  (let ((r (emacs-devtools-mcp-tools-gui--linearize (nth 0 rgb)))
        (g (emacs-devtools-mcp-tools-gui--linearize (nth 1 rgb)))
        (b (emacs-devtools-mcp-tools-gui--linearize (nth 2 rgb))))
    (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))

(defun emacs-devtools-mcp-tools-gui--parse-hex (s)
  "Parse hex color S (`#rgb', `#rrggbb', or `#rrrrggggbbbb') to sRGB floats.
Returns nil when S is not a recognized hex syntax.  Hex is parsed
locally to avoid the batch-mode flakiness of `color-values' on
some Emacs builds, which snaps mid-range hex to extremes."
  (and (stringp s)
       (eq (aref s 0) ?#)
       (let* ((rest (substring s 1))
              (n (length rest)))
         (cond
          ((and (= n 3)
                (string-match-p "\\`[0-9a-fA-F]+\\'" rest))
           (let ((r (string-to-number (substring rest 0 1) 16))
                 (g (string-to-number (substring rest 1 2) 16))
                 (b (string-to-number (substring rest 2 3) 16)))
             (list (/ (* r 17) 255.0)
                   (/ (* g 17) 255.0)
                   (/ (* b 17) 255.0))))
          ((and (= n 6)
                (string-match-p "\\`[0-9a-fA-F]+\\'" rest))
           (list (/ (string-to-number (substring rest 0 2) 16) 255.0)
                 (/ (string-to-number (substring rest 2 4) 16) 255.0)
                 (/ (string-to-number (substring rest 4 6) 16) 255.0)))
          ((and (= n 12)
                (string-match-p "\\`[0-9a-fA-F]+\\'" rest))
           (list (/ (string-to-number (substring rest 0 4) 16) 65535.0)
                 (/ (string-to-number (substring rest 4 8) 16) 65535.0)
                 (/ (string-to-number (substring rest 8 12) 16) 65535.0)))
          (t nil)))))

(defun emacs-devtools-mcp-tools-gui--parse-color (s)
  "Parse color spec S to a list of three sRGB floats; signal on bad input.
S is a hex (`#rgb' / `#rrggbb' / `#rrrrggggbbbb', parsed locally)
or a named color understood by `color-name-to-rgb'.  Inputs longer
than 128 chars are rejected -- legitimate specs are well under
that, and the cap keeps an adversarial caller from feeding huge
strings into `color-name-to-rgb'/`x-parse-color'."
  (unless (stringp s)
    (error "Color must be a string, got %S" s))
  (when (> (length s) 128)
    (error "Color spec too long (%d chars)" (length s)))
  (or (emacs-devtools-mcp-tools-gui--parse-hex s)
      (let ((rgb (color-name-to-rgb s)))
        (and rgb (= (length rgb) 3) rgb))
      (error "Cannot parse color: %s" s)))

(defun emacs-devtools-mcp-tools-gui--contrast (fg bg)
  "Return a plist describing the WCAG contrast between FG and BG.
Both are color spec strings.  Result keys:
  :ratio      raw contrast ratio (float, max 21.0),
  :ratio_str  formatted to two decimals,
  :passes_aa  t when ratio >= 4.5 (normal text),
  :passes_aaa t when ratio >= 7.0 (normal text),
  :passes_aa_large  t when ratio >= 3.0,
  :passes_aaa_large t when ratio >= 4.5."
  (let* ((fg-rgb (emacs-devtools-mcp-tools-gui--parse-color fg))
         (bg-rgb (emacs-devtools-mcp-tools-gui--parse-color bg))
         (lf (emacs-devtools-mcp-tools-gui--luminance fg-rgb))
         (lb (emacs-devtools-mcp-tools-gui--luminance bg-rgb))
         (l1 (max lf lb))
         (l2 (min lf lb))
         (ratio (/ (+ l1 0.05) (+ l2 0.05))))
    (list :ratio ratio
          :ratio_str (format "%.2f" ratio)
          :passes_aa (emacs-devtools-mcp-tools-gui--bool (>= ratio 4.5))
          :passes_aaa (emacs-devtools-mcp-tools-gui--bool (>= ratio 7.0))
          :passes_aa_large (emacs-devtools-mcp-tools-gui--bool
                            (>= ratio 3.0))
          :passes_aaa_large (emacs-devtools-mcp-tools-gui--bool
                             (>= ratio 4.5)))))

(defun emacs-devtools-mcp-tools-gui--face-name (face)
  "Return a stable JSON-clean string for FACE (symbol, string, or list)."
  (cond
   ((null face) "default")
   ((symbolp face) (symbol-name face))
   ((stringp face) face)
   ((listp face)
    ;; A face may be a list of inherited faces, or a property plist
    ;; like (:foreground "red"); collapse both to a printed form.
    (mapconcat #'emacs-devtools-mcp-tools-gui--face-name face ","))
   (t (prin1-to-string face))))

(defun emacs-devtools-mcp-tools-gui--face-at (buffer-name line column)
  "Return the face at BUFFER-NAME's LINE / COLUMN as a plist.
LINE is 1-based.  COLUMN is a 0-based *character offset* from the
start of the line, not a visual column -- a tab counts as one
character regardless of `tab-width', and zero-width characters
still advance the offset.  This matches `point' arithmetic and
keeps the tool deterministic across display configurations.
Out-of-range LINE or COLUMN values raise a structured error
rather than silently clamping to point-min / point-max.
Result has :face plus :foreground and :background resolved
through `face-attribute' so the caller doesn't have to walk
inheritance themselves."
  (let ((b (get-buffer buffer-name)))
    (unless b
      (error "Buffer not found: %s" buffer-name))
    (unless (and (integerp line) (>= line 1))
      (error "Line %S out of range (must be >= 1)" line))
    (unless (and (integerp column) (>= column 0))
      (error "Column %S out of range (must be >= 0)" column))
    (with-current-buffer b
      (save-excursion
        (goto-char (point-min))
        (let ((short (forward-line (1- line))))
          (unless (zerop short)
            (error "Line %d past end of buffer (only %d line%s)"
                   line
                   (- line short)
                   (if (= 1 (- line short)) "" "s"))))
        (let* ((bol (line-beginning-position))
               (eol (line-end-position))
               (len (- eol bol)))
          (when (> column len)
            (error "Column %d past end of line %d (length %d)"
                   column line len))
          (goto-char (+ bol column)))
        (let* ((pos (point))
               (raw (or (get-text-property pos 'face)
                        (get-char-property pos 'face)
                        'default))
               (name (emacs-devtools-mcp-tools-gui--face-name raw))
               (face-sym (cond ((symbolp raw) raw)
                               ((and (listp raw) (symbolp (car raw))
                                     (facep (car raw)))
                                (car raw))
                               (t 'default)))
               (fg (face-attribute face-sym :foreground nil 'default))
               (bg (face-attribute face-sym :background nil 'default)))
          (list :face name
                :position pos
                :foreground (if (stringp fg) fg :json-false)
                :background (if (stringp bg) bg :json-false)))))))

(defun emacs-devtools-mcp-tools-gui--describe-face (name)
  "Return a plist describing face NAME, including inherited attributes."
  (let ((sym (intern-soft name)))
    (unless (and sym (facep sym))
      (error "Unknown face: %s" name))
    (let* ((attrs '(:family :foundry :width :height :weight :slant
                    :foreground :background :underline :overline
                    :strike-through :box :inverse-video :stipple
                    :inherit))
           (out nil))
      (dolist (a attrs)
        (let ((v (face-attribute sym a nil 'default))
              (key (intern (substring (symbol-name a) 1))))
          (cond
           ((eq v 'unspecified) nil)
           ((stringp v)
            (push (cons key v) out))
           ((numberp v)
            (push (cons key v) out))
           ((symbolp v)
            (push (cons key (symbol-name v)) out))
           (t
            (push (cons key (prin1-to-string v)) out)))))
      (list :name (symbol-name sym)
            :doc (or (face-documentation sym) "")
            :attributes (nreverse out)))))

(defun emacs-devtools-mcp-tools-gui--list-faces (filter)
  "Return a sorted list of face name strings, optionally narrowed by FILTER.
FILTER, when non-nil and non-empty, is treated as a regex matched
against the face symbol name.  Filter strings longer than 256
chars or that fail to compile as a regex are rejected so an
adversarial caller cannot pin the regex engine across the whole
face list."
  (let ((re (and filter (not (string-empty-p filter)) filter)))
    (when re
      (when (> (length re) 256)
        (error "Filter regex too long (%d chars)" (length re)))
      (condition-case err
          ;; Smoke-test the regex once before iterating.
          (string-match-p re "")
        (invalid-regexp
         (error "Invalid filter regex: %s" (cadr err)))))
    (let* ((all (face-list))
           (kept (if re
                     (cl-remove-if-not
                      (lambda (f) (string-match-p re (symbol-name f)))
                      all)
                   all)))
      (sort (mapcar #'symbol-name kept) #'string<))))

(defun emacs-devtools-mcp-tools-gui--window-snapshot (win)
  "Return a plist describing window WIN and its buffer."
  (let ((buf (window-buffer win)))
    (list :buffer (buffer-name buf)
          :live (emacs-devtools-mcp-tools-gui--bool (window-live-p win))
          :width (window-total-width win)
          :height (window-total-height win)
          :point (with-current-buffer buf (point))
          :start (window-start win)
          :selected (emacs-devtools-mcp-tools-gui--bool
                     (eq win (selected-window))))))

(defun emacs-devtools-mcp-tools-gui--frame-windows (frame)
  "Walk FRAME and return a flat list of window-snapshot plists."
  (let (out)
    (walk-window-tree
     (lambda (w)
       (push (emacs-devtools-mcp-tools-gui--window-snapshot w) out))
     frame nil nil)
    (nreverse out)))

(defun emacs-devtools-mcp-tools-gui--frame-snapshot (frame)
  "Return a plist describing FRAME's geometry, parameters, and windows."
  (list :name (or (frame-parameter frame 'name) "")
        :visible (emacs-devtools-mcp-tools-gui--bool
                  (frame-visible-p frame))
        :selected (emacs-devtools-mcp-tools-gui--bool
                   (eq frame (selected-frame)))
        :width (frame-parameter frame 'width)
        :height (frame-parameter frame 'height)
        :pixel_width (frame-pixel-width frame)
        :pixel_height (frame-pixel-height frame)
        :left (or (frame-parameter frame 'left) 0)
        :top (or (frame-parameter frame 'top) 0)
        :background (or (frame-parameter frame 'background-color)
                        :json-false)
        :foreground (or (frame-parameter frame 'foreground-color)
                        :json-false)
        :windows (vconcat (emacs-devtools-mcp-tools-gui--frame-windows
                           frame))))

(defun emacs-devtools-mcp-tools-gui--frame-tree (name)
  "Build the frame tree.  Nil NAME yields all frames; else only the named one."
  (let* ((all (frame-list))
         (frames (if name
                     (or (cl-remove-if-not
                          (lambda (f)
                            (equal (frame-parameter f 'name) name))
                          all)
                         (error "Frame not found: %s" name))
                   all)))
    (list :frames
          (vconcat (mapcar #'emacs-devtools-mcp-tools-gui--frame-snapshot
                           frames)))))

(defun emacs-devtools-mcp-tools-gui--graphic-frame ()
  "Return a graphical frame, preferring the selected one, or nil.
A daemon Emacs dispatching over the server socket may have its
dumb terminal frame selected even while a GUI client frame
exists; scanning `frame-list' finds that frame instead of
declaring screenshots unavailable."
  (if (display-graphic-p)
      (selected-frame)
    (cl-find-if #'display-graphic-p (frame-list))))

(defun emacs-devtools-mcp-tools-gui--probe-host-backend ()
  "Probe the host screenshot backend; cache only success.
Returns `x-export-frames' when a trial PNG export succeeds on
some graphical frame (also caching that in
`emacs-devtools-mcp-tools-gui--host-backend'), else returns
`unavailable' *without* caching -- batch mode or a daemon that
has not opened a GUI frame yet should be re-probed on the next
call, since a GUI client frame can appear at any time."
  (or emacs-devtools-mcp-tools-gui--host-backend
      (let* ((frame (emacs-devtools-mcp-tools-gui--graphic-frame))
             (works
              (and frame
                   (condition-case _
                       ;; `x-export-frames' defaults to PDF; we want PNG
                       ;; bytes here so the magic-byte check matches what
                       ;; `--screenshot' will later produce.
                       (let ((bytes (with-selected-frame frame
                                      (x-export-frames nil 'png))))
                         (and (stringp bytes)
                              (>= (length bytes) 8)
                              (string-prefix-p "\x89PNG" bytes)))
                     (error nil)))))
        (if works
            (setq emacs-devtools-mcp-tools-gui--host-backend 'x-export-frames)
          'unavailable))))

(defun emacs-devtools-mcp-tools-gui--resolve-frame (name)
  "Resolve frame NAME to a frame object, or signal on miss.
A nil NAME prefers the selected frame when it is graphical, else
the first graphical frame (the daemon topology), else falls back
to the selected frame so the backend check produces the
unavailability error."
  (cond
   ((null name) (or (emacs-devtools-mcp-tools-gui--graphic-frame)
                    (selected-frame)))
   ((not (stringp name))
    (error "Frame name must be a string, got %S" name))
   (t
    (or (cl-find-if (lambda (f) (equal (frame-parameter f 'name) name))
                    (frame-list))
        (error "Frame not found: %s" name)))))

(defun emacs-devtools-mcp-tools-gui--screenshot (name)
  "Capture frame NAME (or the selected frame) as PNG bytes.
Refuses to encode frames whose pixel area exceeds the configured
soft cap.  Returns a plist suitable for the MCP image content
block, or signals when no working backend is available."
  (let* ((backend (emacs-devtools-mcp-tools-gui--probe-host-backend))
         (frame (emacs-devtools-mcp-tools-gui--resolve-frame name))
         (pw (frame-pixel-width frame))
         (ph (frame-pixel-height frame))
         (cap (* (car emacs-devtools-mcp-screenshot-max-pixels)
                 (cdr emacs-devtools-mcp-screenshot-max-pixels))))
    (unless (eq backend 'x-export-frames)
      (error "Screenshot backend unavailable: %s" backend))
    (when (> (* pw ph) cap)
      (error (concat "Frame too large: %dx%d = %d pixels exceeds area cap "
                     "%d (= %dx%d).  Raise the cap by setting %s to a "
                     "(WIDTH . HEIGHT) cons -- e.g. (cons 3840 2160) for "
                     "4K -- not a single integer.")
             pw ph (* pw ph)
             cap
             (car emacs-devtools-mcp-screenshot-max-pixels)
             (cdr emacs-devtools-mcp-screenshot-max-pixels)
             'emacs-devtools-mcp-screenshot-max-pixels))
    (let* ((bytes (with-selected-frame frame (x-export-frames nil 'png)))
           (b64 (base64-encode-string bytes t)))
      (list :width pw
            :height ph
            :mimeType "image/png"
            :data b64))))

(defun emacs-devtools-mcp-tools-gui--screenshot-content-block (name)
  "Wrap a screenshot of frame NAME in an MCP image content block.
The PNG itself carries width/height; no sibling envelope is added
so the response is exactly the standard MCP `image' block."
  (let* ((shot (emacs-devtools-mcp-tools-gui--screenshot name)))
    (list :content
          (vector (list :type "image"
                        :data (plist-get shot :data)
                        :mimeType (plist-get shot :mimeType))))))

;;;; Tool handlers.

(defun edmcp--tools-color-contrast (params)
  "Handler for `color-contrast'.  PARAMS is the validated request plist."
  (let* ((fg (plist-get params :foreground))
         (bg (plist-get params :background))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-gui--contrast ,fg ,bg))))

(defun edmcp--tools-face-at (params)
  "Handler for `face-at'.  PARAMS is the validated request plist."
  (let* ((buffer (plist-get params :buffer))
         (line (plist-get params :line))
         (column (plist-get params :column))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-gui--face-at ,buffer ,line ,column))))

(defun edmcp--tools-describe-face (params)
  "Handler for `describe-face'.  PARAMS is the validated request plist."
  (let* ((name (plist-get params :name))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-gui--describe-face ,name))))

(defun edmcp--tools-list-faces (params)
  "Handler for `list-faces'.  PARAMS is the validated request plist."
  (let* ((filter (plist-get params :filter))
         (cursor (plist-get params :cursor))
         (target (plist-get params :target))
         (page-size emacs-devtools-mcp-faces-page-size)
         (items (unless cursor
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(emacs-devtools-mcp-tools-gui--list-faces ,filter))))
         (paged (emacs-devtools-mcp--paginate items page-size cursor))
         (page (nth 0 paged))
         (next (nth 1 paged))
         (out (list :faces (vconcat page))))
    (when next (setq out (plist-put out :next_cursor next)))
    out))

(defun edmcp--tools-get-frame-tree (params)
  "Handler for `get-frame-tree'.  PARAMS is the validated request plist."
  (let* ((frame (plist-get params :frame))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-gui--frame-tree ,frame))))

(defun edmcp--tools-screenshot-frame (params)
  "Handler for `screenshot-frame'.  PARAMS is the validated request plist."
  (let* ((frame (plist-get params :frame))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-gui--screenshot-content-block ,frame))))

;;;; Tool definitions.

(emacs-devtools-mcp-deftool color-contrast
    "Compute the WCAG contrast ratio between FOREGROUND and BACKGROUND."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((foreground . (:type "string"))
                         (background . (:type "string"))
                         (target     . ,emacs-devtools-mcp-target-schema))
            :required ["foreground" "background"])
  :handler #'edmcp--tools-color-contrast)

(emacs-devtools-mcp-deftool face-at
    "Return the face at LINE (1-based) and COLUMN (0-based) of BUFFER."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((buffer . (:type "string"))
                         (line   . (:type "integer"))
                         (column . (:type "integer"))
                         (target . ,emacs-devtools-mcp-target-schema))
            :required ["buffer" "line" "column"])
  :handler #'edmcp--tools-face-at)

(emacs-devtools-mcp-deftool describe-face
    "Return inheritance-resolved attributes and docstring for face NAME."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((name   . (:type "string"))
                         (target . ,emacs-devtools-mcp-target-schema))
            :required ["name"])
  :handler #'edmcp--tools-describe-face)

(emacs-devtools-mcp-deftool list-faces
    "List all face symbols in alphabetical order, optionally narrowed by FILTER."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((filter . (:type ["string" "null"]))
                         (cursor . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-list-faces)

(emacs-devtools-mcp-deftool get-frame-tree
    "Return frames -> windows -> buffer metadata for the selected display."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((frame  . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-get-frame-tree)

(emacs-devtools-mcp-deftool screenshot-frame
    "Export FRAME to a base64-encoded PNG image content block.
Returns a structured error when no display backend is available
(batch mode, no DISPLAY).  The frame's pixel dimensions must fit
within `emacs-devtools-mcp-screenshot-max-pixels'."
  :cost :slow
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((frame  . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-screenshot-frame)

(provide 'emacs-devtools-mcp-tools-gui)
;;; emacs-devtools-mcp-tools-gui.el ends here
