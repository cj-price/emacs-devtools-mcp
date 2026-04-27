;;; emacs-devtools-mcp-tools-init.el --- init.el tools  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Three tools that operate on an init file rather than a running
;; Emacs session: `init-lint', `startup-profile', `bisect-init'.  All
;; three run the file inside a fresh `emacs -Q --batch' subprocess, so
;; the user's live Emacs is never re-evaluated and the tools cannot
;; corrupt host state.  The path is validated through
;; `emacs-devtools-mcp-auth-validate-init-path' before the subprocess
;; starts, defending against agents that try to evaluate arbitrary
;; files outside the configured init allowlist.
;;
;; These tools do not accept the standard `target' parameter because
;; they spawn their own transient subprocess; the spawn registry is
;; for tools that hold a live Emacs.  Output is run through
;; `emacs-devtools-mcp-redact' before returning.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-server)
(require 'emacs-devtools-mcp-auth)
(require 'emacs-devtools-mcp-spawn)

(define-error 'emacs-devtools-mcp-init-error
  "Init-tool error")

(defcustom emacs-devtools-mcp-init-batch-timeout 30
  "Seconds a single batch-Emacs probe may run before being killed.
Caps `init-lint', `startup-profile', and each `bisect-init' probe
so a hung init.el cannot wedge the host."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-bisect-max-probes 32
  "Hard cap on probes performed by `bisect-init' before giving up.
Bisection over N forms takes ceil(log2(N)) probes; the cap covers
init files up to ~4 billion forms with a safety margin and prevents
runaway bisection if the predicate is non-monotonic."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

;;;; Subprocess plumbing.

(defun edmcp--tools-init-default-file ()
  "Return the agent's intended default init file.
Resolves to `user-init-file' if non-nil and an existing string;
otherwise falls back to `~/.config/emacs/init.el' (the
XDG-conformant location).  The fallback is a heuristic guess --
the resulting path still goes through the allowlist check, so an
unconfigured user gets a clear allowlist error rather than a
silent wrong-file load."
  (or (and (stringp user-init-file)
           (file-exists-p user-init-file)
           user-init-file)
      (expand-file-name "init.el" "~/.config/emacs")))

(defun edmcp--tools-init-resolve-file (file)
  "Resolve FILE through the init allowlist and return its truename.
FILE may be nil (use default) or a string.  Signals when the path
fails the allowlist check."
  (let ((target (or file (edmcp--tools-init-default-file))))
    (emacs-devtools-mcp-auth-validate-init-path target)))

(defun edmcp--tools-init-reject-read-eval (label text)
  "Signal when LABEL's TEXT carries a `#.' or `#@' reader macro.
The `#.' construct evaluates at read time -- accepting it from
agent input or subordinate output would punch through every
other isolation gate in this file.  `#@' (compiled docstring
references) is never legitimately printed by our subordinate."
  (when (and (stringp text)
             (string-match-p "#[.@]" text))
    (signal 'emacs-devtools-mcp-init-error
            (list (format "%s contains a reader macro (#./#@); refusing"
                          label)))))

(defun edmcp--tools-init-read-trusted-string (label text)
  "Read one Lisp form from LABEL's TEXT after rejecting reader macros.
Parse errors and `#.'/`#@' presence both raise
`emacs-devtools-mcp-init-error' so the dispatch layer wraps
them in an `isError' envelope rather than a JSON-RPC protocol
error code."
  (edmcp--tools-init-reject-read-eval label text)
  (condition-case err
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (read (current-buffer)))
    (error
     (signal 'emacs-devtools-mcp-init-error
             (list (format "%s parse error: %s"
                           label (error-message-string err)))))))

(defun edmcp--tools-init-call-batch (eval-form &optional extra-args)
  "Run `emacs -Q --batch' with EVAL-FORM and return (rc . merged-output).
EVAL-FORM is a Lisp form printed via `prin1-to-string' and passed
through `--eval'.  EXTRA-ARGS is an optional list of additional
argv strings inserted before `--eval'.  The child is run via
`make-process' (async) so `with-timeout' can actually fire and
kill it; synchronous `call-process' would block the host event
loop and defeat the cap."
  (let* ((eval-str (let ((print-level nil)
                         (print-length nil)
                         (print-circle t))
                     (prin1-to-string eval-form)))
         (argv (append (list "-Q" "--batch")
                       extra-args
                       (list "--eval" eval-str)))
         (buf (generate-new-buffer " *edmcp-init-batch*" t))
         (proc nil)
         (timed-out nil))
    (unwind-protect
        (progn
          (setq proc (make-process
                      :name "edmcp-init-batch"
                      :buffer buf
                      :command (cons emacs-devtools-mcp-spawn-emacs-program
                                     argv)
                      :connection-type 'pipe
                      :noquery t
                      :stderr buf))
          (with-timeout (emacs-devtools-mcp-init-batch-timeout
                         (setq timed-out t))
            (while (process-live-p proc)
              (accept-process-output proc 0.1)))
          (when timed-out
            (when (process-live-p proc) (kill-process proc))
            ;; Give the child a moment to actually exit so its buffer
            ;; output is flushed before we read it.
            (with-timeout (1 nil)
              (while (process-live-p proc)
                (accept-process-output proc 0.05)))
            (signal 'emacs-devtools-mcp-init-error
                    (list (format "init batch exceeded %ds"
                                  emacs-devtools-mcp-init-batch-timeout))))
          (cons (process-exit-status proc)
                (with-current-buffer buf (buffer-string))))
      (when (and proc (process-live-p proc)) (kill-process proc))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;;; init-lint.

(defun edmcp--tools-init-lint-classify-line (line)
  "Tag LINE as :error, :warning, or nil based on `byte-compile-file' format.
Lines printed by `byte-compile-file' / `byte-compile-warn' have a
recognizable shape (`FILE:LINE:COL: Error: ...' or `Warning:'
suffix on a continuation line); the test is loose so unfamiliar
diagnostic text still surfaces in `:raw'."
  (cond
   ((string-match-p "\\bError:" line) :error)
   ((string-match-p "\\(?:Warning\\|warning\\):" line) :warning)
   (t nil)))

(defun edmcp--tools-init-lint-runner (file-real)
  "Byte-compile FILE-REAL in batch and return a diagnostics plist.
The compiled output goes to a throwaway temp directory so this
tool is read-only with respect to the user's Emacs config tree."
  (let* ((tmp-dir (with-file-modes #o700
                    (make-temp-file "edmcp-init-lint-" t)))
         (form `(progn
                  (require 'bytecomp)
                  (let ((default-directory ,tmp-dir)
                        (byte-compile-dest-file-function
                         (lambda (src)
                           (expand-file-name
                            (concat (file-name-nondirectory src) "c")
                            ,tmp-dir)))
                        (byte-compile-error-on-warn nil)
                        (byte-compile-warnings t))
                    (byte-compile-file ,file-real)))))
    (unwind-protect
        (let* ((res (edmcp--tools-init-call-batch form))
               (rc (car res))
               (raw (cdr res))
               (warnings nil)
               (errors nil))
          (dolist (line (split-string raw "\n" t))
            (pcase (edmcp--tools-init-lint-classify-line line)
              (:error (push line errors))
              (:warning (push line warnings))))
          (list :file file-real
                :exit_code rc
                :warnings (vconcat (nreverse warnings))
                :errors (vconcat (nreverse errors))
                :raw (emacs-devtools-mcp-redact raw)))
      (when (file-directory-p tmp-dir)
        (delete-directory tmp-dir t)))))

(defun edmcp--tools-init-lint (params)
  "Handler for `init-lint'.  PARAMS is the validated request plist."
  (let* ((file (plist-get params :file))
         (file-real (edmcp--tools-init-resolve-file file)))
    (edmcp--tools-init-lint-runner file-real)))

;;;; startup-profile.

(defun edmcp--tools-init-startup-profile-runner (file-real)
  "Run FILE-REAL under `profiler-start' and return CPU log + timing.
The subprocess prints a single sexp on stdout containing the
elapsed seconds and the (truncated) `profiler-cpu-log' tree.  Any
profiler errors are caught with `unwind-protect' so the profiler
is always stopped."
  (let* ((form `(let ((start (current-time)))
                  (profiler-start 'cpu)
                  (unwind-protect
                      (condition-case err
                          (load ,file-real nil t)
                        (error (princ (format "LOAD-ERROR %S\n" err))))
                    (profiler-stop))
                  (let* ((elapsed (float-time (time-since start)))
                         (log (profiler-cpu-log))
                         (entries
                          (when log
                            (let (acc)
                              (maphash
                               (lambda (backtrace count)
                                 (push (list :count count
                                             :frames
                                             (mapcar
                                              (lambda (f)
                                                (cond
                                                 ((symbolp f) (symbol-name f))
                                                 ((stringp f) f)
                                                 (t (format "%S" f))))
                                              (append backtrace nil)))
                                       acc))
                               log)
                              ;; Top 50 hotspots by sample count.
                              (cl-sort acc #'> :key (lambda (e)
                                                      (plist-get e :count)))))))
                    (princ "EDMCP-PROFILE-BEGIN\n")
                    (let ((print-level nil)
                          (print-length nil))
                      (prin1 (list :elapsed elapsed
                                   :samples (length entries)
                                   :top (cl-subseq
                                         entries 0
                                         (min 50 (length entries))))))
                    (princ "\nEDMCP-PROFILE-END\n"))))
         (res (edmcp--tools-init-call-batch form))
         (rc (car res))
         (raw (cdr res))
         ;; The result sexp is the last balanced form on stdout; load
         ;; errors are echoed via princ above and lifted into
         ;; `:load_error' so a `samples: 0' result is distinguishable
         ;; from "init crashed before profiling could observe it".
         (parsed-pair (edmcp--tools-init-parse-profile-output raw))
         (parsed (car parsed-pair))
         (parse-error (cdr parsed-pair))
         (load-error (edmcp--tools-init-extract-load-error raw)))
    (list :file file-real
          :exit_code rc
          :elapsed (or (plist-get parsed :elapsed) 0.0)
          :samples (or (plist-get parsed :samples) 0)
          :top (vconcat
                (mapcar #'edmcp--tools-init-redact-top-entry
                        (append (or (plist-get parsed :top) []) nil)))
          :parse_error (if parse-error parse-error :json-false)
          :load_error (if load-error load-error :json-false)
          :raw (emacs-devtools-mcp-redact raw))))

(defun edmcp--tools-init-extract-load-error (raw)
  "Return the redacted `LOAD-ERROR' line from RAW, or nil when absent.
The startup-profile runner wraps the user `load' in a
`condition-case' that echoes `LOAD-ERROR %S' on failure -- the
caller can react to a missing package or syntax slip without
having to grep `:raw'."
  (when (string-match "^LOAD-ERROR \\(.*\\)$" raw)
    (emacs-devtools-mcp-redact (match-string 1 raw))))

(defun edmcp--tools-init-redact-top-entry (entry)
  "Redact stringly-typed frames in profile ENTRY before exposing them.
ENTRY is a plist like `(:count N :frames (\"foo\" ...))'.  The
frame names originate in the spawned init -- a malicious init
can embed credentials in symbol names that survive the `:raw'
redaction layer because they're returned as structured fields
rather than free text.  Walks each frame string through
`emacs-devtools-mcp-redact'."
  (list :count (plist-get entry :count)
        :frames (mapcar (lambda (f)
                          (if (stringp f)
                              (emacs-devtools-mcp-redact f)
                            f))
                        (plist-get entry :frames))))

(defun edmcp--tools-init-parse-profile-output (raw)
  "Extract the EDMCP-PROFILE sentinel-bracketed sexp from RAW.
Returns a cons (PARSED . ERROR-STRING).  PARSED is the read plist
or nil; ERROR-STRING is nil on success and a short message
otherwise.  Searches from the *last* `EDMCP-PROFILE-END' backward
to the matching `EDMCP-PROFILE-BEGIN' so an init that itself
prints the sentinel cannot poison the parser."
  (let ((begin-tag "EDMCP-PROFILE-BEGIN\n")
        (end-tag "\nEDMCP-PROFILE-END"))
    (condition-case err
        (let* ((end-pos
                (let ((idx 0) last)
                  (while (setq idx (string-match end-tag raw idx))
                    (setq last idx)
                    (cl-incf idx))
                  last))
               (begin-pos (and end-pos
                               (let ((idx 0) last)
                                 (while (and (setq idx (string-match
                                                        begin-tag raw idx))
                                             (< idx end-pos))
                                   (setq last idx)
                                   (cl-incf idx))
                                 last))))
          (if (and begin-pos end-pos
                   (< begin-pos end-pos))
              (let ((sexp (substring raw
                                     (+ begin-pos (length begin-tag))
                                     end-pos)))
                (cons (edmcp--tools-init-read-trusted-string
                       "profile result" sexp)
                      nil))
            (cons nil "no profile sentinel in output")))
      (emacs-devtools-mcp-init-error
       (cons nil (cadr err)))
      (error
       (cons nil (error-message-string err))))))

(defun edmcp--tools-init-startup-profile (params)
  "Handler for `startup-profile'.  PARAMS is the validated plist."
  (let* ((file (plist-get params :file))
         (file-real (edmcp--tools-init-resolve-file file)))
    (edmcp--tools-init-startup-profile-runner file-real)))

;;;; bisect-init.

(defun edmcp--tools-init-bisect-form-positions (file-real)
  "Return a list of plists describing each top-level form of FILE-REAL.
Each plist has `:line-start', `:line-end' (1-based inclusive),
and `:end-pos' (the buffer character position immediately after
the form, used to slice prefixes verbatim).  Refuses files
containing `#.' or `#@' reader macros so reading cannot evaluate
agent-influenced content host-side."
  (with-temp-buffer
    (insert-file-contents file-real)
    (edmcp--tools-init-reject-read-eval
     (format "init file %s" file-real)
     (buffer-string))
    (goto-char (point-min))
    (cl-labels ((skip-noise ()
                  ;; Skip whitespace and `;'-introduced line comments so
                  ;; the parser tolerates a trailing `;;; foo.el ends here'
                  ;; footer (and any other comment-only tail).
                  (let (last)
                    (while (not (equal last (point)))
                      (setq last (point))
                      (skip-chars-forward " \t\n\r")
                      (when (eq (char-after) ?\;)
                        (forward-line 1))))))
      (let ((positions nil)
            (clean-exit nil))
        (condition-case _done
            (while t
              (skip-noise)
              ;; Distinguish a clean exit (no more forms) from an
              ;; unbalanced-parens parse failure: SET the flag *before*
              ;; raising end-of-file ourselves, so the handler can tell
              ;; which path got us there.  If `read' below raises
              ;; end-of-file from inside an unbalanced form, the flag is
              ;; still nil and the handler signals a parse error.
              (when (eobp)
                (setq clean-exit t)
                (signal 'end-of-file nil))
              (let* ((beg (point))
                     (form (read (current-buffer)))
                     (end (point)))
                (ignore form)
                (push (list :line-start (line-number-at-pos beg)
                            :line-end (line-number-at-pos end)
                            :end-pos end)
                      positions)))
          (end-of-file
           (unless clean-exit
             (signal 'emacs-devtools-mcp-init-error
                     (list (format "cannot parse top-level forms in %s"
                                   file-real)))))
          (error (signal 'emacs-devtools-mcp-init-error
                         (list (format "cannot parse top-level forms in %s"
                                       file-real)))))
        (nreverse positions)))))

(defun edmcp--tools-init-bisect-write-prefix (file-real positions n)
  "Slice FILE-REAL using POSITIONS to keep its first N forms in a temp file.
POSITIONS is the result of `bisect-form-positions' for FILE-REAL.
Writing the literal byte range preserves the `lexical-binding'
cookie, comments, and reader-syntax (`#''/`#''') that a
`prin1'/`read' round-trip would mangle.  Returns the temp file
path; caller deletes it."
  (let* ((end-pos (plist-get (nth (1- n) positions) :end-pos))
         (tmp (with-file-modes #o600
                (make-temp-file "edmcp-bisect-prefix-" nil ".el"))))
    (condition-case err
        (with-temp-file tmp
          (insert-file-contents file-real)
          (delete-region end-pos (point-max)))
      (error
       (when (file-exists-p tmp) (delete-file tmp))
       (signal (car err) (cdr err))))
    tmp))

(defun edmcp--tools-init-bisect-probe (prefix-file predicate-form)
  "Load PREFIX-FILE in batch then evaluate PREDICATE-FORM; return (STATUS . RAW).
STATUS is one of `:reproduces', `:load-failed', or `:not-reproduced'.
PREDICATE-FORM is evaluated inside the child; errors during its
evaluation count as non-reproducing so a malformed predicate
doesn't pin bisection to an arbitrary form.  The child prints a
literal sentinel (`EDMCP-PROBE-T' or `EDMCP-PROBE-NIL') rather
than a `%S'-formatted value, so a predicate returning a string
that contains the sentinel cannot mislead the parser.  Load
failures are reported separately so the runner can disclose them
in the result rather than silently conflating a load-time crash
with a predicate hit."
  (let* ((form `(progn
                  (load ,prefix-file nil t)
                  (princ
                   (if (condition-case _e
                           (eval ',predicate-form t)
                         (error nil))
                       "EDMCP-PROBE-T\n"
                     "EDMCP-PROBE-NIL\n"))))
         (res (edmcp--tools-init-call-batch form))
         (rc (car res))
         (raw (cdr res)))
    (cond
     ((not (zerop rc))             (cons :load-failed     raw))
     ((string-match-p "^EDMCP-PROBE-T$" raw) (cons :reproduces raw))
     (t                            (cons :not-reproduced raw)))))

(defun edmcp--tools-init-bisect-runner (file-real predicate-str)
  "Bisect FILE-REAL against PREDICATE-STR; return culprit info.
PREDICATE-STR is a Lisp form (as a string) that returns non-nil
iff the problem reproduces.  Returns a plist with `:culprit_form'
\(1-based index into the form list), `:line_start', `:line_end',
and `:probes' (the number of probes performed)."
  (let* ((predicate-form
          (edmcp--tools-init-read-trusted-string
           "predicate" predicate-str))
         (positions (edmcp--tools-init-bisect-form-positions file-real))
         (n (length positions))
         (probes 0)
         (load-failed-probes 0)
         (lo 1)
         (hi n)
         (best nil)
         (full-status nil))
    (when (zerop n)
      (signal 'emacs-devtools-mcp-init-error
              (list "init file has no top-level forms")))
    ;; Sanity-check: full file must reproduce.  Without this gate the
    ;; predicate could be non-monotonic and the converged culprit
    ;; meaningless.
    (let ((tmp (edmcp--tools-init-bisect-write-prefix file-real positions n)))
      (unwind-protect
          (let* ((probe (edmcp--tools-init-bisect-probe tmp predicate-form))
                 (status (car probe)))
            (cl-incf probes)
            (setq full-status status)
            (when (eq status :load-failed) (cl-incf load-failed-probes))
            (when (eq status :not-reproduced)
              (signal 'emacs-devtools-mcp-init-error
                      (list "predicate did not reproduce with full init"))))
        (delete-file tmp)))
    (while (and (< lo hi)
                (< probes emacs-devtools-mcp-bisect-max-probes))
      (let* ((mid (/ (+ lo hi) 2))
             (tmp (edmcp--tools-init-bisect-write-prefix
                   file-real positions mid))
             (probe (unwind-protect
                        (edmcp--tools-init-bisect-probe tmp predicate-form)
                      (delete-file tmp)))
             (status (car probe)))
        (cl-incf probes)
        (when (eq status :load-failed) (cl-incf load-failed-probes))
        (if (memq status '(:reproduces :load-failed))
            (setq hi mid
                  best mid)
          (setq lo (1+ mid)))))
    (let* ((culprit (or best lo))
           (entry (nth (1- culprit) positions)))
      (list :file file-real
            :culprit_form culprit
            :forms_total n
            :line_start (plist-get entry :line-start)
            :line_end (plist-get entry :line-end)
            :probes probes
            :load_failed_probes load-failed-probes
            :full_status (symbol-name (or full-status :not-reproduced))))))

(defun edmcp--tools-init-bisect (params)
  "Handler for `bisect-init'.  PARAMS is the validated plist.
Validates `predicate' against emptiness before resolving the file
path so a missing argument fails fast without a filesystem walk."
  (let ((predicate (plist-get params :predicate)))
    (unless (and (stringp predicate) (not (string-empty-p predicate)))
      (signal 'emacs-devtools-mcp-init-error
              (list "predicate must be a non-empty string")))
    (let ((file-real
           (edmcp--tools-init-resolve-file (plist-get params :file))))
      (edmcp--tools-init-bisect-runner file-real predicate))))

;;;; Tool definitions.

(emacs-devtools-mcp-deftool init-lint
    "Byte-compile FILE in `emacs -Q --batch' and report diagnostics.
FILE defaults to `user-init-file' (or the XDG path).  Path is
validated against `emacs-devtools-mcp-init-allowlist' before
execution.  The compiled output goes to a temp directory and is
discarded -- this tool does not modify the user's config tree.
Marked read-only because byte-compile only evaluates
`eval-when-compile' / `defmacro' bodies in a throwaway
subprocess, so host-server state is unaffected.  Output is
redacted."
  :cost :slow
  :read-only t
  :destructive nil
  :idempotent t
  :schema `(:type "object"
            :properties ((file . (:type ["string" "null"]))))
  :handler #'edmcp--tools-init-lint)

(emacs-devtools-mcp-deftool startup-profile
    "Run FILE under the CPU profiler in `emacs -Q --batch'.
Returns elapsed seconds plus the top 50 hotspot frames from
`profiler-cpu-log'.  Path is allowlist-checked.  Marked
destructive because loading FILE executes its full body inside
the subprocess, which may perform arbitrary I/O even though the
host's state is unchanged.  Not idempotent because CPU profile
sampling is wall-clock dependent.  Output is redacted."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((file . (:type ["string" "null"]))))
  :handler #'edmcp--tools-init-startup-profile)

(emacs-devtools-mcp-deftool bisect-init
    "Binary-search FILE for the form that triggers PREDICATE.
PREDICATE is a Lisp form (string) that returns non-nil iff the
problem reproduces.  Each probe is one `emacs -Q --batch'
subprocess loading a prefix of FILE.  Returns the 1-based
`culprit_form' index plus its `line_start'/`line_end' and a
`load_failed_probes' counter that flags when convergence was
driven by load-time crashes rather than predicate hits.  Path
is allowlist-checked; predicate errors are caught and treated
as non-reproducing so a bad predicate doesn't pin to an
arbitrary form.  Marked destructive because PREDICATE is
arbitrary agent-supplied Lisp and runs in each probe
subprocess.  Not idempotent: the predicate may have side
effects or be non-deterministic (e.g. wall-clock-dependent),
and bisection only converges deterministically when PREDICATE
is monotonic over prefixes -- a contract the agent is
responsible for upholding."
  :cost :slow
  :read-only nil
  :destructive t
  :idempotent nil
  :schema `(:type "object"
            :properties ((file      . (:type ["string" "null"]))
                         (predicate . (:type "string")))
            :required ["predicate"])
  :handler #'edmcp--tools-init-bisect)

(provide 'emacs-devtools-mcp-tools-init)
;;; emacs-devtools-mcp-tools-init.el ends here
