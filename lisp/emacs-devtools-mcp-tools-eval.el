;;; emacs-devtools-mcp-tools-eval.el --- Eval and debug tools  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Eval, edebug, backtrace capture, and trace.  Six tools share this
;; file because they all sit at the eval-and-introspect boundary:
;;
;;   `eval-elisp'           -- read FORM, evaluate, return prin1 + msg delta
;;   `edebug-instrument'    -- mark a defun for edebug stepping
;;   `edebug-uninstrument'  -- restore the original definition
;;   `capture-backtrace'    -- eval FORM with `debug' wired up to capture
;;   `trace-function'       -- attach `trace-function-foreground'
;;   `untrace-function'     -- detach traces from a function
;;   `trace-log'            -- read a trace buffer with cursor pagination
;;
;; Output is run through `emacs-devtools-mcp-redact' so common
;; secret-bearing prefixes (auth-source-, epg-, tramp-) never leave
;; the host.  All tools accept the standard `target' parameter and
;; route through `emacs-devtools-mcp-spawn-call'.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'jsonrpc)
(require 'edebug)
(require 'find-func)
(require 'backtrace)
(require 'trace)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-server)
(require 'emacs-devtools-mcp-spawn)

(defcustom emacs-devtools-mcp-trace-log-page-size 100
  "Default page size (in lines) for `trace-log'."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-trace-log-line-max-bytes 4096
  "Per-line byte cap for `trace-log' output.
A single traced call can print arbitrarily large argument values;
without a cap, one such line could exceed
`emacs-devtools-mcp-max-response-bytes' on its own and abort the
entire page.  Lines longer than this limit are truncated and
suffixed with a `[truncated N bytes]' marker."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-backtrace-max-bytes 65536
  "Byte cap for `capture-backtrace' backtrace text.
Bound recursion can produce backtraces that exceed
`emacs-devtools-mcp-max-response-bytes', which would drop the
entire response as `payload_too_large' and lose the point of
failure.  The tail of the backtrace is kept (containing the
signaling frame) when the cap is hit."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defconst emacs-devtools-mcp-tools-eval--trace-buffer-regexp
  "\\`\\*trace"
  "Anchor for buffer names accepted by `trace-log'.
`trace.el' creates `*trace-output*' (and per-derived variants
like `*trace-output-foo*').  Restricting reads to this prefix
prevents `trace-log' from doubling as an arbitrary buffer-read
primitive that bypasses the redaction layer.")

(defvar emacs-devtools-mcp-tools-eval--edebug-originals
  (make-hash-table :test 'eq)
  "Map of function symbol to its definition prior to edebug instrumentation.
Stored on instrument and consulted on uninstrument so we can restore
the function without re-reading source from disk.")

;;;; eval-elisp.

(defun emacs-devtools-mcp-tools-eval--run (form pl plen)
  "Evaluate FORM with `print-level' PL and `print-length' PLEN.
Returns a plist with:
  :value    the printed result, or absent on error
  :messages the *Messages* delta, redacted
  :error    the error-message string, or absent on success

This function is the single source of truth for the `eval-elisp'
tool's runtime behavior; it must remain self-contained so the
same code path can be replayed inside a subordinate Emacs once
spawn support lands."
  (let* ((messages-buf (get-buffer "*Messages*"))
         (start (and messages-buf
                     (with-current-buffer messages-buf (point-max))))
         (result nil)
         (err nil))
    (condition-case oops
        (let ((print-level pl)
              (print-length plen))
          (setq result (prin1-to-string (eval form t))))
      (error
       (setq err (error-message-string oops))))
    (let* ((delta (and messages-buf start
                       (with-current-buffer messages-buf
                         (buffer-substring-no-properties
                          start (point-max)))))
           (redacted (emacs-devtools-mcp-redact delta))
           (base (list :messages (or redacted ""))))
      (if err
          (append base (list :error err))
        ;; Redact :value too -- a printed result of e.g.
        ;; (auth-source-search ...) would otherwise leak past the
        ;; *Messages* gate.  Best-effort and line-grain like the
        ;; rest of the redaction layer.
        (append base (list :value (or (emacs-devtools-mcp-redact result)
                                      "")))))))

(defun edmcp--tools-eval-elisp (params)
  "Handler for `eval-elisp'.  PARAMS is the validated request plist."
  (let* ((form-str (plist-get params :form))
         (pl (or (plist-get params :print_level) 6))
         (plen (or (plist-get params :print_length) 100))
         (target (plist-get params :target))
         (form
          (condition-case err
              (with-temp-buffer
                (insert form-str)
                (goto-char (point-min))
                (read (current-buffer)))
            (error
             (jsonrpc-error
              :code -32602
              :message (format "form parse error: %s"
                               (error-message-string err)))))))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-eval--run ',form ,pl ,plen))))

;;;; edebug-instrument / edebug-uninstrument.

(defun emacs-devtools-mcp-tools-eval--edebug-instrument (function-name)
  "Instrument the function named by FUNCTION-NAME for edebug stepping.
Saves the original `symbol-function' value before instrumenting so
`edebug-uninstrument' can restore it without re-reading the source
file.  When FUNCTION-NAME has already been instrumented through
this package, returns the same shape without re-running
`edebug-instrument-function' -- this preserves any advice or
redefinition layered on top after the original save.  Signals
when the symbol is not bound to a function or when the function
lacks a discoverable source location."
  (let ((sym (intern-soft function-name)))
    (unless (and sym (fboundp sym))
      (error "Unknown function: %s" function-name))
    (cond
     ((gethash sym emacs-devtools-mcp-tools-eval--edebug-originals)
      ;; Already instrumented in this session -- no-op for true
      ;; idempotency.  Re-running `edebug-instrument-function' on an
      ;; already-instrumented body would re-wrap any advice applied
      ;; in the meantime; the saved original would then no longer
      ;; round-trip through `edebug-uninstrument'.
      (list :function function-name :instrumented t :already t))
     (t
      (puthash sym (symbol-function sym)
               emacs-devtools-mcp-tools-eval--edebug-originals)
      ;; `edebug-instrument-function' returns the list of definitions
      ;; it instrumented, or signals `no-debug-info' when source is
      ;; unknown.
      (edebug-instrument-function sym)
      (list :function function-name :instrumented t :already :json-false)))))

(defun emacs-devtools-mcp-tools-eval--edebug-uninstrument (function-name)
  "Remove edebug instrumentation from FUNCTION-NAME.
When the function was instrumented through this package, the
saved `symbol-function' is restored.  Otherwise we open the
defining file and `eval-defun' it with the variable
`edebug-all-defs' bound to nil, clearing instrumentation that
pre-dated this session."
  (require 'edebug)
  (require 'find-func)
  (let* ((sym (intern-soft function-name))
         (orig (and sym
                    (gethash sym
                             emacs-devtools-mcp-tools-eval--edebug-originals))))
    (unless (and sym (fboundp sym))
      (error "Unknown function: %s" function-name))
    (cond
     (orig
      (fset sym orig)
      (remhash sym emacs-devtools-mcp-tools-eval--edebug-originals)
      (list :function function-name
            :instrumented :json-false
            :restored t))
     (t
      (let ((bp (ignore-errors (find-function-noselect sym))))
        (unless bp
          (error "No source for %s -- cannot uninstrument" function-name))
        (with-current-buffer (car bp)
          (save-excursion
            (goto-char (cdr bp))
            (let ((edebug-all-defs nil))
              (eval-defun nil)))))
      (list :function function-name
            :instrumented :json-false
            :restored :json-false)))))

;;;; capture-backtrace.

(defun emacs-devtools-mcp-tools-eval--capture-backtrace (form pl plen)
  "Evaluate FORM; on error or quit, return the captured backtrace.
PL and PLEN bound `print-level' and `print-length' for the
returned `:value'.  When FORM signals, `signal-hook-function' is
used to record the live frame stack via `backtrace' BEFORE
unwinding -- so the trace reflects the point of failure, not the
point where `condition-case' caught.  This avoids the
`debug-on-error' / `debug-on-signal' machinery, which is
process-global and has surprising interactions with ERT's batch
runner.

Returns a plist with `:value' or `:error', `:backtrace' (string,
empty when none), and `:messages' (the *Messages* delta,
redacted)."
  (require 'backtrace)
  (let* ((messages-buf (get-buffer "*Messages*"))
         (msg-start (and messages-buf
                         (with-current-buffer messages-buf (point-max))))
         (bt-text "")
         (recording t)
         (result nil)
         (err nil))
    (let ((signal-hook-function
           (lambda (_signal _data)
             ;; `signal-hook-function' is invoked at signal time,
             ;; before unwinding, in the signaling frame.  Record the
             ;; backtrace here so it reflects the point of failure.
             ;; Flip the recording flag off FIRST so any signal raised
             ;; by `with-output-to-string' or `backtrace' itself
             ;; doesn't re-enter (which would loop forever via this
             ;; hook).
             (when recording
               (setq recording nil)
               (setq bt-text
                     (with-output-to-string (backtrace)))))))
      (condition-case oops
          (let ((print-level pl)
                (print-length plen))
            (setq result (prin1-to-string (eval form t))))
        ((error quit)
         (setq err (error-message-string oops)))))
    (let* ((delta (and messages-buf msg-start
                       (with-current-buffer messages-buf
                         (buffer-substring-no-properties
                          msg-start (point-max)))))
           (redacted (emacs-devtools-mcp-redact (or delta "")))
           ;; Tail-truncate the backtrace before redaction so the cap
           ;; preserves the signaling frames at the bottom rather than
           ;; the older ones at the top.
           (bt-cap emacs-devtools-mcp-backtrace-max-bytes)
           (bt-bytes (string-bytes bt-text))
           (bt-trimmed
            (if (and bt-cap (> bt-bytes bt-cap))
                (concat (format "[truncated %d bytes from head]\n"
                                (- bt-bytes bt-cap))
                        (substring bt-text (max 0 (- (length bt-text)
                                                     bt-cap))))
              bt-text))
           (bt-redacted (emacs-devtools-mcp-redact bt-trimmed)))
      (if err
          (list :error err
                :backtrace (or bt-redacted "")
                :messages (or redacted ""))
        (list :value (or (emacs-devtools-mcp-redact result) "")
              :backtrace ""
              :messages (or redacted ""))))))

;;;; trace-function / untrace-function / trace-log.

(defun emacs-devtools-mcp-tools-eval--trace-function (function-name buffer-name)
  "Attach `trace-function-foreground' to FUNCTION-NAME.
Trace output goes to BUFFER-NAME or `trace-buffer' when nil.
Returns the resolved buffer name and function name."
  (require 'trace)
  (let* ((sym (intern-soft function-name))
         (buf-name (or buffer-name trace-buffer)))
    (unless (and sym (fboundp sym))
      (error "Unknown function: %s" function-name))
    (let ((buf (get-buffer-create buf-name)))
      (trace-function-foreground sym buf))
    (list :function function-name
          :buffer buf-name)))

(defun emacs-devtools-mcp-tools-eval--untrace-function (function-name)
  "Remove all trace advice from FUNCTION-NAME.
Returns the function name; idempotent when no trace was attached."
  (require 'trace)
  (let ((sym (intern-soft function-name)))
    (unless (and sym (fboundp sym))
      (error "Unknown function: %s" function-name))
    (untrace-function sym)
    (list :function function-name)))

(defun emacs-devtools-mcp-tools-eval--trace-log-lines (buffer-name line-cap)
  "Return the lines of BUFFER-NAME as a list.
BUFFER-NAME defaults to `trace-buffer' and must match
`emacs-devtools-mcp-tools-eval--trace-buffer-regexp' so this tool
cannot double as an arbitrary buffer-read primitive.  LINE-CAP
bounds each line in bytes; longer lines are tail-truncated to
`[truncated N bytes]'.  Each line is run through
`emacs-devtools-mcp-redact' before return so secrets in traced
arguments cannot bypass the redaction layer.  Signals when the
buffer doesn't exist or violates the name pattern."
  (let* ((buf-name (or buffer-name trace-buffer))
         (pattern emacs-devtools-mcp-tools-eval--trace-buffer-regexp))
    (unless (string-match-p pattern buf-name)
      (error "Refusing to read non-trace buffer: %s" buf-name))
    (let ((buf (get-buffer buf-name)))
      (unless buf
        (error "Trace buffer not found: %s" buf-name))
      (let ((lines (with-current-buffer buf
                     (split-string
                      (buffer-substring-no-properties (point-min) (point-max))
                      "\n"))))
        (mapcar
         (lambda (line)
           (let* ((bytes (string-bytes line))
                  (capped (if (and line-cap (> bytes line-cap))
                              (concat (substring line 0 (min (length line)
                                                             line-cap))
                                      (format " [truncated %d bytes]"
                                              (- bytes line-cap)))
                            line)))
             (emacs-devtools-mcp-redact capped)))
         lines)))))

;;;; Tool handlers.

(defun edmcp--tools-edebug-instrument (params)
  "Handler for `edebug-instrument'.  PARAMS is the validated request plist."
  (let* ((function-name (plist-get params :function))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-eval--edebug-instrument ,function-name))))

(defun edmcp--tools-edebug-uninstrument (params)
  "Handler for `edebug-uninstrument'.  PARAMS is the validated plist."
  (let* ((function-name (plist-get params :function))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-eval--edebug-uninstrument ,function-name))))

(defun edmcp--tools-capture-backtrace (params)
  "Handler for `capture-backtrace'.  PARAMS is the validated plist."
  (let* ((form-str (plist-get params :form))
         (pl (or (plist-get params :print_level) 6))
         (plen (or (plist-get params :print_length) 100))
         (target (plist-get params :target))
         (form
          (condition-case err
              (with-temp-buffer
                (insert form-str)
                (goto-char (point-min))
                (read (current-buffer)))
            (error
             (jsonrpc-error
              :code -32602
              :message (format "form parse error: %s"
                               (error-message-string err)))))))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-eval--capture-backtrace
       ',form ,pl ,plen))))

(defun edmcp--tools-trace-function (params)
  "Handler for `trace-function'.  PARAMS is the validated plist."
  (let* ((function-name (plist-get params :function))
         (buffer (plist-get params :buffer))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-eval--trace-function
       ,function-name ,buffer))))

(defun edmcp--tools-untrace-function (params)
  "Handler for `untrace-function'.  PARAMS is the validated plist."
  (let* ((function-name (plist-get params :function))
         (target (plist-get params :target)))
    (emacs-devtools-mcp-spawn-call
     target
     `(emacs-devtools-mcp-tools-eval--untrace-function ,function-name))))

(defun edmcp--tools-trace-log (params)
  "Handler for `trace-log'.  PARAMS is the validated plist.
Reads the named trace BUFFER (default `trace-buffer'), splits on
newlines, and serves a page of lines using the standard cursor
store.  Trailing empty lines from the buffer's terminal newline
are preserved so paginated reassembly yields identical text."
  (let* ((buffer (plist-get params :buffer))
         (cursor (plist-get params :cursor))
         (target (plist-get params :target))
         (page-size emacs-devtools-mcp-trace-log-page-size)
         (line-cap emacs-devtools-mcp-trace-log-line-max-bytes)
         ;; Cursor pages re-use the server-side tail; only the first
         ;; page round-trips to the target to read the buffer.
         (lines (unless cursor
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(emacs-devtools-mcp-tools-eval--trace-log-lines
                     ,buffer ,line-cap))))
         (paged (emacs-devtools-mcp--paginate lines page-size cursor))
         (page (nth 0 paged))
         (next (nth 1 paged))
         (out (list :lines (vconcat page))))
    (when next (setq out (plist-put out :next_cursor next)))
    out))

;;;; Tool definitions.

(emacs-devtools-mcp-deftool eval-elisp
    "Evaluate FORM in TARGET and return its printed value.
Captures the *Messages* delta and any error.  Output is redacted
to drop lines mentioning auth-source/epg/tramp before transit."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((form          . (:type "string"))
                         (print_level   . (:type ["integer" "null"]))
                         (print_length  . (:type ["integer" "null"]))
                         (target        . ,emacs-devtools-mcp-target-schema))
            :required ["form"])
  :handler #'edmcp--tools-eval-elisp)

(emacs-devtools-mcp-deftool edebug-instrument
    "Mark FUNCTION for edebug stepping.
The original `symbol-function' value is recorded so
`edebug-uninstrument' can restore it without re-reading source."
  :cost :fast
  :read-only nil
  :destructive t
  :idempotent t
  :schema `(:type "object"
            :properties ((function . (:type "string"))
                         (target   . ,emacs-devtools-mcp-target-schema))
            :required ["function"])
  :handler #'edmcp--tools-edebug-instrument)

(emacs-devtools-mcp-deftool edebug-uninstrument
    "Remove edebug instrumentation from FUNCTION."
  :cost :fast
  :read-only nil
  :destructive t
  :idempotent t
  :schema `(:type "object"
            :properties ((function . (:type "string"))
                         (target   . ,emacs-devtools-mcp-target-schema))
            :required ["function"])
  :handler #'edmcp--tools-edebug-uninstrument)

(emacs-devtools-mcp-deftool capture-backtrace
    "Evaluate FORM and return any signaled backtrace.
`signal-hook-function' is used to record the live frame stack via
`backtrace' at signal time, so the trace reflects the point of
failure, not the point where the package's `condition-case'
caught.  Output is tail-truncated at
`emacs-devtools-mcp-backtrace-max-bytes' and redacted."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((form         . (:type "string"))
                         (print_level  . (:type ["integer" "null"]))
                         (print_length . (:type ["integer" "null"]))
                         (target       . ,emacs-devtools-mcp-target-schema))
            :required ["form"])
  :handler #'edmcp--tools-capture-backtrace)

(emacs-devtools-mcp-deftool trace-function
    "Attach `trace-function-foreground' to FUNCTION; output goes to BUFFER."
  :cost :fast
  :read-only nil
  :destructive t
  :idempotent t
  :schema `(:type "object"
            :properties ((function . (:type "string"))
                         (buffer   . (:type ["string" "null"]))
                         (target   . ,emacs-devtools-mcp-target-schema))
            :required ["function"])
  :handler #'edmcp--tools-trace-function)

(emacs-devtools-mcp-deftool untrace-function
    "Remove all trace advice from FUNCTION."
  :cost :fast
  :read-only nil
  :destructive t
  :idempotent t
  :schema `(:type "object"
            :properties ((function . (:type "string"))
                         (target   . ,emacs-devtools-mcp-target-schema))
            :required ["function"])
  :handler #'edmcp--tools-untrace-function)

(emacs-devtools-mcp-deftool trace-log
    "Return the lines of BUFFER (default `trace-buffer'), paginated."
  :cost :fast
  :read-only t
  :destructive nil
  :idempotent t
  :schema `(:type "object"
            :properties ((buffer . (:type ["string" "null"]))
                         (cursor . (:type ["string" "null"]))
                         (target . ,emacs-devtools-mcp-target-schema)))
  :handler #'edmcp--tools-trace-log)

(provide 'emacs-devtools-mcp-tools-eval)
;;; emacs-devtools-mcp-tools-eval.el ends here
