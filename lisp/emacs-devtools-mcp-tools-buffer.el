;;; emacs-devtools-mcp-tools-buffer.el --- Buffer-state introspection  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  cj-price
;; Homepage: https://github.com/cj-price/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.5
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Read-only buffer introspection plus `ert-run' and `describe-hooks'.
;; Tools route through `emacs-devtools-mcp-spawn-call' so the same
;; code paths run on the host and on subordinate Emacsen.
;; Pagination uses the cursor store from
;; `emacs-devtools-mcp.el'; redaction is applied to any
;; *Messages*-derived surface.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'ert)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-spawn)

(defcustom emacs-devtools-mcp-buffer-list-page-size 50
  "Default page size for `list-buffers' / `list-messages' / `list-warnings'."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-buffer-substring-default-max-bytes (* 64 1024)
  "Default per-call byte cap for `buffer-substring' when client omits `max_bytes'."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

;;;; Pure runtime helpers (run on the host or a subordinate via spawn-call).

(defun emacs-devtools-mcp-tools-buffer--snapshot-list (filter)
  "Return a list of buffer plists, optionally narrowed by regex FILTER.
Plist keys: :name, :file, :mode, :size, :modified.  Buffers whose
names start with a space (internal) are skipped unless FILTER
explicitly matches them."
  (let ((re (and filter (not (string-empty-p filter)) filter))
        (out nil))
    (dolist (b (buffer-list))
      (let ((n (buffer-name b)))
        (when (and n
                   (or re (not (string-prefix-p " " n)))
                   (or (null re) (string-match-p re n)))
          (with-current-buffer b
            (push (list :name n
                        :file (or buffer-file-name :json-false)
                        :mode (symbol-name major-mode)
                        :size (buffer-size)
                        :modified (if (buffer-modified-p) t :json-false))
                  out)))))
    (nreverse out)))

(defun emacs-devtools-mcp-tools-buffer--state (name)
  "Return a buffer-state plist for buffer NAME, or signal if it does not exist."
  (let ((b (get-buffer name)))
    (unless b
      (error "Buffer not found: %s" name))
    (with-current-buffer b
      (list :name (buffer-name)
            :file (or buffer-file-name :json-false)
            :mode (symbol-name major-mode)
            :size (buffer-size)
            :modified (if (buffer-modified-p) t :json-false)
            :read_only (if buffer-read-only t :json-false)
            :point (point)
            :mark (or (mark t) :json-false)
            :line (line-number-at-pos)
            :column (current-column)
            :point_min (point-min)
            :point_max (point-max)
            :narrowed (if (or (/= (point-min) 1)
                              (/= (point-max) (1+ (buffer-size))))
                          t
                        :json-false)))))

(defun emacs-devtools-mcp-tools-buffer--substring
    (name start end max-bytes)
  "Return part of buffer NAME between START and END as a plain string.
Text properties are dropped: the wire is JSON, which has no place
to carry them, so claiming to keep them would be a lie.  Output
is capped to MAX-BYTES; result plist carries :text and, when
truncated, :truncated t plus :next_offset.  When START or END
fall outside the buffer they are clamped, but raw inputs that
form an inverted range (start > end) signal before clamping --
otherwise the resulting error would mention silently-rewritten
bounds.  The returned :text is run through
`emacs-devtools-mcp-redact' so a caller cannot read raw
*Messages* / backtrace lines that the dedicated tools would have
scrubbed.  :next_offset stays in source-buffer coordinates and
is unaffected by the post-redaction shrink of :text."
  (let ((b (get-buffer name)))
    (unless b
      (error "Buffer not found: %s" name))
    (with-current-buffer b
      (let* ((pmin (point-min))
             (pmax (point-max)))
        (when (and (integerp start) (integerp end) (> start end))
          (error "Invalid range: start %d > end %d (buffer span %d..%d)"
                 start end pmin pmax))
        (let* ((s0 (max pmin (or start pmin)))
               (e0 (min pmax (or end pmax))))
          (when (> s0 e0)
            (error
             "Invalid range: start %s > end %s (buffer span %d..%d)"
             (if start (number-to-string start) "nil")
             (if end (number-to-string end) "nil")
             pmin pmax))
          (let* ((raw (buffer-substring-no-properties s0 e0))
                 (bytes (string-bytes raw))
                 (truncated (> bytes max-bytes)))
            (if (not truncated)
                (list :text (or (emacs-devtools-mcp-redact raw) "")
                      :truncated :json-false)
              (let* ((acc nil)
                     (acc-bytes 0)
                     (i 0)
                     (len (length raw))
                     (next-offset s0))
                (while (and (< i len) (< acc-bytes max-bytes))
                  (let* ((ch (aref raw i))
                         (cb (string-bytes (string ch))))
                    (when (> (+ acc-bytes cb) max-bytes)
                      (setq i len))
                    (when (< i len)
                      (push ch acc)
                      (setq acc-bytes (+ acc-bytes cb)
                            next-offset (1+ next-offset)
                            i (1+ i)))))
                (list :text (or (emacs-devtools-mcp-redact
                                 (concat (nreverse acc)))
                                "")
                      :truncated t
                      :next_offset next-offset)))))))))

(defun emacs-devtools-mcp-tools-buffer--messages-tail (n)
  "Return the last N lines of the *Messages* buffer, redacted.
N defaults to `emacs-devtools-mcp-buffer-list-page-size' when nil.
Non-positive N is rejected with a structured error -- silently
returning `[]' for `n=0' would mask a bug in the caller."
  (when (and n (<= n 0))
    (error "n must be positive, got %d" n))
  (let ((buf (get-buffer "*Messages*"))
        (cap (or n emacs-devtools-mcp-buffer-list-page-size)))
    (if (not buf)
        '()
      (with-current-buffer buf
        (let* ((all (buffer-substring-no-properties (point-min) (point-max)))
               (lines (split-string all "\n"))
               (non-empty (cl-remove-if #'string-empty-p lines))
               (tail (last non-empty cap))
               (kept (split-string
                      (emacs-devtools-mcp-redact
                       (mapconcat #'identity tail "\n"))
                      "\n")))
          (cl-remove-if #'string-empty-p kept))))))

(defun emacs-devtools-mcp-tools-buffer--warnings-list ()
  "Return the *Warnings* buffer contents as one string per warning paragraph.
Each paragraph is run through `emacs-devtools-mcp-redact' before
return so an `auth-source-' / `epg-' / `tramp-' warning cannot
bypass the redaction layer the way `list-messages' is gated."
  (let ((buf (get-buffer "*Warnings*")))
    (if (not buf)
        '()
      (with-current-buffer buf
        (let* ((all (buffer-substring-no-properties (point-min) (point-max)))
               (paras (split-string all "\n\n" t "[ \t\n]+")))
          (delq nil
                (mapcar (lambda (p)
                          (let ((scrubbed (emacs-devtools-mcp-redact p)))
                            (and scrubbed
                                 (not (string-empty-p scrubbed))
                                 scrubbed)))
                        paras)))))))

(defun edmcp--ert-parse-selector (selector)
  "Parse SELECTOR (a string or nil/t) into an ERT selector value.
Nil and the literal string \"t\" map to t (all loaded tests).  An
empty string is treated as nil so missing-vs-empty is not a
correctness pitfall.  Anything else is read with the Lisp reader
after rejecting the unsafe reader syntax in
`emacs-devtools-mcp-unsafe-reader-re' (`#.'/`#@' escapes and
`#N='/`#N#' labels) -- so the full ERT
selector grammar is available (`(tag :fast)', `(member t1 t2)',
`(or A B)', `(satisfies PRED)', etc.) without exposing reader-time
code execution.  A bare regexp must be wired through the reader as
a quoted string -- `\"^foo$\"' on the wire reads to the string
literal that ERT then matches against test names."
  (cond
   ((null selector) t)
   ((eq selector t) t)
   ((stringp selector)
    (cond
     ((string-empty-p selector) t)
     ((string= selector "t") t)
     ((string-match-p emacs-devtools-mcp-unsafe-reader-re selector)
      (error
       "Invalid ert selector: refuses unsafe reader syntax #., #@, #N=/#N# (got %S)"
       selector))
     (t
      (condition-case err
          (let ((parsed (read-from-string selector)))
            (unless (and (consp parsed)
                         (= (cdr parsed) (length selector)))
              ;; Trailing junk after the first sexp would be silently
              ;; discarded by `read-from-string'; fail loudly so the
              ;; caller sees that, e.g., `"foo bar"' did not match a
              ;; valid grammar.
              (error "Trailing characters after %S in selector %S"
                     (car parsed) selector))
            (car parsed))
        (error
         (error "Invalid ert selector %S: %s"
                selector (error-message-string err)))))))
   (t selector)))

(defun edmcp--ert-collect-failures (stats)
  "Build a vector of (:name :message) plists, one per failure in STATS.
\"Failure\" is the union of `ert-test-failed-p' and the quit/abort
result types -- anything ERT classifies as not-passed-not-skipped.
Skipped runs are reported separately via the `:skipped' counter
and do not appear in the returned vector."
  (let (failures)
    (mapc
     (lambda (test)
       (let ((result (ert-test-most-recent-result test)))
         (when (and result
                    (not (ert-test-passed-p result))
                    (not (ert-test-skipped-p result)))
           (let ((message
                  (cond
                   ((and (ert-test-result-with-condition-p result)
                         (ert-test-result-with-condition-condition result))
                    (let ((c
                           (ert-test-result-with-condition-condition result)))
                      (condition-case nil
                          (error-message-string c)
                        (error (format "%S" c)))))
                   (t (format "%s" (type-of result))))))
             (push (list :name (symbol-name (ert-test-name test))
                         :message
                         (or (emacs-devtools-mcp-redact message) ""))
                   failures)))))
     (append (ert--stats-tests stats) nil))
    (vconcat (nreverse failures))))

(defun emacs-devtools-mcp-tools-buffer--ert-run (selector)
  "Run ERT for SELECTOR and return a plist summary.
SELECTOR is parsed by `edmcp--ert-parse-selector' -- see that
function for the accepted grammar.  Use the literal \"t\" or
nil/omission to run every loaded test (the slow-tool timeout
still applies).  The result plist carries:
  :total    -- number of tests selected,
  :passed   -- count of expected-pass results,
  :failed   -- count of unexpected (failed) results,
  :skipped  -- count of skipped tests,
  :ok       -- t if `:failed' is zero, else `:json-false',
  :failures -- vector of `(:name :message)' plists, one per
               failed test, redacted; empty when `:failed' is 0."
  (let* ((sel (edmcp--ert-parse-selector selector))
         (stats (ert-run-tests sel (lambda (&rest _)) nil))
         (passed (ert-stats-completed-expected stats))
         (failed (ert-stats-completed-unexpected stats))
         (skipped (ert-stats-skipped stats))
         (total (ert-stats-total stats))
         (failures (edmcp--ert-collect-failures stats)))
    (list :total total
          :passed passed
          :failed failed
          :skipped skipped
          :ok (if (zerop failed) t :json-false)
          :failures failures)))

(defun emacs-devtools-mcp-tools-buffer--describe-hooks (hook)
  "Describe HOOK or, when HOOK is nil, list every bound hook symbol.
A bound hook is any symbol whose name ends in `-hook' whose value
is a list.  Returns a JSON-shaped plist in either branch:
  nil HOOK   -> (:hooks [\"name1\" \"name2\" ...])
  named HOOK -> (:name STR :functions [\"f1\" ...])"
  (cond
   ((null hook)
    (let (hooks)
      (mapatoms
       (lambda (s)
         (let ((n (symbol-name s)))
           (when (and (string-suffix-p "-hook" n)
                      (boundp s)
                      (listp (symbol-value s)))
             (push n hooks)))))
      (list :hooks (vconcat (sort hooks #'string<)))))
   (t
    (let* ((sym (if (stringp hook) (intern-soft hook) hook)))
      (unless (and sym (boundp sym))
        (error "Unbound hook: %s" hook))
      (list :name (symbol-name sym)
            :functions
            (vconcat
             (mapcar (lambda (f)
                       (cond
                        ((symbolp f) (symbol-name f))
                        ((byte-code-function-p f) "#<bytecode>")
                        ((functionp f) (format "%S" f))
                        (t (format "%S" f))))
                     (symbol-value sym))))))))

;;;; Tool handlers.

(defun edmcp--tools-list-buffers (params)
  "Handler for `list-buffers'.  PARAMS is the validated request plist."
  (let* ((filter (plist-get params :filter))
         (cursor (plist-get params :cursor))
         (target (plist-get params :target))
         (page-size emacs-devtools-mcp-buffer-list-page-size)
         (items (unless cursor
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(emacs-devtools-mcp-tools-buffer--snapshot-list
                     ,filter))))
         (paged (emacs-devtools-mcp--paginate items page-size cursor))
         (page (nth 0 paged))
         (next (nth 1 paged))
         (out (list :buffers (vconcat page))))
    (when next (setq out (plist-put out :next_cursor next)))
    out))

(defun edmcp--tools-buffer-state (params)
  "Handler for `buffer-state'.  PARAMS is the validated request plist."
  (let* ((name (plist-get params :buffer))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-buffer--state ,name))))

(defun edmcp--tools-buffer-substring (params)
  "Handler for `buffer-substring'.  PARAMS is the validated request plist."
  (let* ((name (plist-get params :buffer))
         (start (plist-get params :start))
         (end (plist-get params :end))
         (max-bytes (or (plist-get params :max_bytes)
                        emacs-devtools-mcp-buffer-substring-default-max-bytes))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-buffer--substring
       ,name ,start ,end ,max-bytes))))

(defun edmcp--tools-list-messages (params)
  "Handler for `list-messages'.  PARAMS is the validated request plist.
A non-positive `:n' is rejected up-front, even when `:cursor' is
also supplied -- mixing a continuation cursor with a malformed
`:n' is a caller bug, and silently letting the cursor win would
mask it (the same silent-clamping pattern that hid `n=0' before
fix d08804d)."
  (let* ((n (plist-get params :n))
         (cursor (plist-get params :cursor))
         (target (plist-get params :target))
         (page-size emacs-devtools-mcp-buffer-list-page-size)
         (_ (when (and n (<= n 0))
              (error "n must be positive, got %d" n)))
         (items (unless cursor
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(emacs-devtools-mcp-tools-buffer--messages-tail ,n))))
         (paged (emacs-devtools-mcp--paginate items page-size cursor))
         (page (nth 0 paged))
         (next (nth 1 paged))
         (out (list :messages (vconcat page))))
    (when next (setq out (plist-put out :next_cursor next)))
    out))

(defun edmcp--tools-list-warnings (params)
  "Handler for `list-warnings'.  PARAMS is the validated request plist."
  (let* ((cursor (plist-get params :cursor))
         (target (plist-get params :target))
         (page-size emacs-devtools-mcp-buffer-list-page-size)
         (items (unless cursor
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(emacs-devtools-mcp-tools-buffer--warnings-list))))
         (paged (emacs-devtools-mcp--paginate items page-size cursor))
         (page (nth 0 paged))
         (next (nth 1 paged))
         (out (list :warnings (vconcat page))))
    (when next (setq out (plist-put out :next_cursor next)))
    out))

(defun edmcp--tools-ert-run (params)
  "Handler for `ert-run'.  PARAMS is the validated request plist."
  (let* ((selector (plist-get params :selector))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-buffer--ert-run ,selector))))

(defun edmcp--tools-describe-hooks (params)
  "Handler for `describe-hooks'.  PARAMS is the validated request plist."
  (let* ((hook (plist-get params :hook))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-buffer--describe-hooks ,hook))))

;;;; Tool definitions.

(emacs-devtools-mcp-deftool list-buffers
    "List live buffers, optionally narrowed by regex FILTER."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((filter . (:type ["string" "null"]))
                         (cursor . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-list-buffers)

(emacs-devtools-mcp-deftool buffer-state
    "Return point/mark/mode/file metadata for BUFFER."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((buffer . (:type "string"))
                         (target . ,emacs-devtools-mcp-target-schema))
            :required ["buffer"])
  :handler #'edmcp--tools-buffer-state)

(emacs-devtools-mcp-deftool buffer-substring
    "Return up to MAX_BYTES of BUFFER between START and END as plain text.
Sets `truncated: true' + `next_offset' when the cap is hit.  Text
properties are not returned -- the JSON wire has no place to
carry them, so the result is always a plain string."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((buffer          . (:type "string"))
                         (start           . (:type ["integer" "null"]))
                         (end             . (:type ["integer" "null"]))
                         (max_bytes       . (:type ["integer" "null"]))
                         (target          . ,emacs-devtools-mcp-target-schema))
            :required ["buffer"])
  :handler #'edmcp--tools-buffer-substring)

(emacs-devtools-mcp-deftool list-messages
    "Return the last N lines of *Messages* (default page size), redacted."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((n      . (:type ["integer" "null"]))
                         (cursor . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-list-messages)

(emacs-devtools-mcp-deftool list-warnings
    "Return the contents of the *Warnings* buffer, paragraph-split."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((cursor . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-list-warnings)

(emacs-devtools-mcp-deftool ert-run
    "Run ERT for SELECTOR (default: all tests) and return a summary plist.
SELECTOR is parsed by the Lisp reader after rejecting `#.'/`#@'
reader-macro escapes, so the full ERT selector grammar is
available:
  - nil or \"t\"           run every loaded test;
  - \"my-test-name\"       run that single test (must be loaded);
  - \"\\\"^foo-\\\"\"      regexp -- a quoted string matches names;
  - \"(tag :fast)\"        all tests carrying the `:fast' tag;
  - \"(member t1 t2)\"     a hand-picked set;
  - \"(or A B)\", \"(and A B)\", \"(not A)\", \"(satisfies PRED)\"
                          combine the above.

The result plist carries `:total', `:passed', `:failed',
`:skipped', `:ok', and `:failures' -- a vector of `(:name
:message)' plists with the error-message-string of each
failed test, redacted via the standard layer."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((selector . (:type ["string" "null"]))
                         (target   . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-ert-run)

(emacs-devtools-mcp-deftool describe-hooks
    "List all bound hooks, or the contents of a specific HOOK."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((hook   . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-describe-hooks)

(provide 'emacs-devtools-mcp-tools-buffer)
;;; emacs-devtools-mcp-tools-buffer.el ends here
