;;; emacs-devtools-mcp-spawn.el --- Subordinate Emacs lifecycle  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  cj-price
;; Homepage: https://github.com/cj-price/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Spawn / attach / kill / list a subordinate Emacs daemon, plus the
;; central dispatch primitive every tool handler ends with:
;;
;;   (emacs-devtools-mcp-spawn-call target form)
;;
;; TARGET is nil or `(:host t)' for the user's running Emacs, or
;; `(:spawn HANDLE)' for a subordinate Emacs.  Handlers must never
;; branch on TARGET themselves -- one code path for host vs spawn is
;; the rule.
;;
;; Daemons are started with `emacs -Q --bg-daemon=NAME' (no init), or
;; `-Q --bg-daemon=NAME -l INIT' when the agent supplies an init file
;; that passes `emacs-devtools-mcp-auth-validate-init-path'.  Headless
;; mode (Xvfb) is gated for a follow-up; passing `:headless t' raises
;; a structured error so the gap is visible to clients.
;;
;; Each handle is a 16-character hex token.  The matching server name
;; is `edmcp-spawn-<HANDLE>' and is validated against
;; `[A-Za-z0-9_-]+' before reaching `make-process'.  Handles idle past
;; `emacs-devtools-mcp-spawn-idle-timeout' are reaped on a 60-second
;; timer and on `kill-emacs-hook'.
;;
;; The eval round-trip routes through `emacsclient -s NAME --eval
;; STR'.  STR is built via `prin1-to-string' over an explicit argv
;; list -- never a shell.  The daemon's reply is pre-scanned for the
;; `#.' read-time eval reader macro and rejected if present, so a
;; compromised or buggy daemon cannot drive code execution in the host
;; through the `read' that decodes the reply.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-auth)

(define-error 'emacs-devtools-mcp-spawn-error
  "Subordinate Emacs error")

(defcustom emacs-devtools-mcp-spawn-idle-timeout 1800
  "Seconds a subordinate Emacs may sit idle before the reaper kills it.
Idle is measured from the last `emacs-devtools-mcp-spawn-call'
that selected the handle.  The reaper runs on a 60-second timer
and on `kill-emacs-hook'."
  :type 'natnum
  :group 'emacs-devtools-mcp-spawn
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-spawn-max-handles 4
  "Maximum number of subordinate Emacs daemons tracked at once."
  :type 'natnum
  :group 'emacs-devtools-mcp-spawn
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-spawn-ready-timeout 10
  "Seconds to poll a freshly-started daemon before declaring it dead."
  :type 'natnum
  :group 'emacs-devtools-mcp-spawn
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-spawn-emacs-program
  (or (executable-find "emacs") "emacs")
  "Path to the `emacs' binary used to start subordinate daemons."
  :type 'string
  :group 'emacs-devtools-mcp-spawn
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-spawn-emacsclient-program
  (or (executable-find "emacsclient") "emacsclient")
  "Path to the `emacsclient' binary used to talk to subordinate daemons."
  :type 'string
  :group 'emacs-devtools-mcp-spawn
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defvar emacs-devtools-mcp-spawn--handles (make-hash-table :test 'equal)
  "Map of handle string to a record plist.
Record fields: :handle, :server-name, :pid, :headless, :init,
:attached, :created, :last-used.")

(defvar emacs-devtools-mcp-spawn--reaper-timer nil
  "Repeating idle reaper timer object, or nil when not installed.")

(defconst edmcp--spawn-server-name-re "\\`[A-Za-z0-9_-]+\\'"
  "Regex every server name must match before reaching `call-process'.")

(defconst edmcp--spawn-server-prefix "edmcp-spawn-"
  "Prefix on auto-generated server names.")

(defun edmcp--spawn-validate-server-name (name)
  "Signal `emacs-devtools-mcp-spawn-error' unless NAME is shell-safe.
Acceptance is `[A-Za-z0-9_-]+', non-empty.  We pass NAME to
`emacsclient -s NAME' as an argv element so shell metacharacters
cannot inject -- this check exists to keep server-file paths and
`*Messages*' lines tidy, and to make logs grep-friendly."
  (unless (and (stringp name)
               (not (string-empty-p name))
               (string-match-p edmcp--spawn-server-name-re name))
    (signal 'emacs-devtools-mcp-spawn-error
            (list (format "invalid server name: %S" name))))
  name)

(defun edmcp--spawn-alloc-handle ()
  "Return a fresh 16-character hex handle drawn from `/dev/urandom'."
  (emacs-devtools-mcp-random-hex 8))

(defun edmcp--spawn-server-name-for (handle)
  "Return the auto server name paired with HANDLE."
  (concat edmcp--spawn-server-prefix handle))

(defun edmcp--spawn-lookup (handle)
  "Return the record for HANDLE, or signal if unknown."
  (or (gethash handle emacs-devtools-mcp-spawn--handles)
      (signal 'emacs-devtools-mcp-spawn-error
              (list (format "unknown handle: %s" handle)))))

(defun edmcp--spawn-touch (handle)
  "Update HANDLE's `:last-used' timestamp to now."
  (let ((rec (edmcp--spawn-lookup handle)))
    (setq rec (plist-put rec :last-used (float-time)))
    (puthash handle rec emacs-devtools-mcp-spawn--handles)
    rec))

(defun edmcp--spawn-record-public (rec)
  "Project REC into the wire shape used by tool handlers.
Returns a plist with snake_case keys that round-trips through
`json-serialize' without surprises."
  (let* ((last (plist-get rec :last-used))
         (idle (max 0 (round (- (float-time) last))))
         (expires (round (+ last emacs-devtools-mcp-spawn-idle-timeout))))
    (list :handle (plist-get rec :handle)
          :server_name (plist-get rec :server-name)
          :pid (plist-get rec :pid)
          :headless (if (plist-get rec :headless) t :json-false)
          :attached (if (plist-get rec :attached) t :json-false)
          :idle_seconds idle
          :expires_at expires)))

(defun edmcp--spawn-call-process (program args &optional output-buffer)
  "Run PROGRAM with ARGS argv (no shell).
OUTPUT-BUFFER receives stdout/stderr (default: a fresh temp
buffer).  Returns (cons EXIT-CODE OUTPUT-STRING).  Always uses an
explicit argv list -- never `start-process-shell-command' or
`shell-command-to-string' -- so spaces, quotes, and other shell
metacharacters in any argument are inert."
  (if output-buffer
      (cons (apply #'call-process program nil output-buffer nil args)
            (with-current-buffer output-buffer (buffer-string)))
    (with-temp-buffer
      (let ((rc (apply #'call-process program nil t nil args)))
        (cons rc (buffer-string))))))

(defun edmcp--spawn-emacsclient-ping (server-name)
  "Return the PID for SERVER-NAME if the daemon answers, else nil.
A nil return means the daemon is not (yet) accepting clients --
either it is still booting, has died, or never existed.  Used by
both the readiness probe and `attach-emacs'."
  (let ((res (edmcp--spawn-call-process
              emacs-devtools-mcp-spawn-emacsclient-program
              (list "-s" server-name "--eval" "(emacs-pid)"))))
    (when (zerop (car res))
      (let ((out (string-trim (cdr res))))
        (when (string-match-p "\\`[0-9]+\\'" out)
          (string-to-number out))))))

(defun edmcp--spawn-wait-ready (server-name)
  "Poll SERVER-NAME until it responds; return its PID or signal.
Polls every 100 ms up to `emacs-devtools-mcp-spawn-ready-timeout'."
  (let ((deadline (+ (float-time)
                     emacs-devtools-mcp-spawn-ready-timeout))
        (pid nil))
    (while (and (null pid) (< (float-time) deadline))
      (setq pid (edmcp--spawn-emacsclient-ping server-name))
      (unless pid (sleep-for 0.1)))
    (or pid
        (signal 'emacs-devtools-mcp-spawn-error
                (list (format "daemon %s did not become ready in %ds"
                              server-name
                              emacs-devtools-mcp-spawn-ready-timeout))))))

(defun edmcp--spawn-bootstrap-args ()
  "Return argv prefix to load this package into a fresh `emacs -Q' daemon.
Without this prefix, `emacsclient --eval' calls from the host
that reference `emacs-devtools-mcp-tools-*' functions fail with
`void-function', since `-Q' skips both `init.el' and the default
`package.el' `load-path' injection."
  (let ((dir (file-name-directory
              (or (locate-library "emacs-devtools-mcp")
                  (signal 'emacs-devtools-mcp-spawn-error
                          (list (concat "cannot bootstrap subordinate "
                                        "Emacs: emacs-devtools-mcp not on "
                                        "load-path")))))))
    (list "-L" dir
          "--eval" "(require 'emacs-devtools-mcp)"
          "--eval" "(require 'emacs-devtools-mcp-server)")))

(defun edmcp--spawn-start-bg-daemon (server-name extra-args)
  "Run `emacs -Q --bg-daemon=SERVER-NAME EXTRA-ARGS' synchronously.
The daemon detaches; the parent exits as soon as the fork
succeeds.  We then call `edmcp--spawn-wait-ready' to confirm the
daemon is accepting clients.  Returns the daemon PID.  Injects
the bootstrap argv between the daemon flag and EXTRA-ARGS so the
package is loaded before any user `-l INIT' runs."
  (let* ((cmd-args (append (list "-Q" (format "--bg-daemon=%s" server-name))
                           (edmcp--spawn-bootstrap-args)
                           extra-args))
         (res (edmcp--spawn-call-process
               emacs-devtools-mcp-spawn-emacs-program cmd-args)))
    (unless (zerop (car res))
      (signal 'emacs-devtools-mcp-spawn-error
              (list (format "emacs --bg-daemon=%s failed (rc=%d): %s"
                            server-name
                            (car res)
                            (string-trim (cdr res))))))
    (edmcp--spawn-wait-ready server-name)))

(defun edmcp--spawn-ensure-reaper ()
  "Install the 60-second reaper timer if absent."
  (unless (and emacs-devtools-mcp-spawn--reaper-timer
               (memq emacs-devtools-mcp-spawn--reaper-timer timer-list))
    (setq emacs-devtools-mcp-spawn--reaper-timer
          (run-with-timer 60 60 #'edmcp--spawn-reaper-tick))))

(defun edmcp--spawn-reaper-tick ()
  "Kill every spawned handle idle past `emacs-devtools-mcp-spawn-idle-timeout'.
Attached handles are skipped: the idle timeout is a resource cap on
daemons this package started, not a license to reap daemons the user
launched out-of-band."
  (let ((now (float-time))
        (dead nil))
    (maphash
     (lambda (h rec)
       (unless (plist-get rec :attached)
         (let ((idle (- now (plist-get rec :last-used))))
           (when (>= idle emacs-devtools-mcp-spawn-idle-timeout)
             (push h dead)))))
     emacs-devtools-mcp-spawn--handles)
    (dolist (h dead)
      (ignore-errors (emacs-devtools-mcp-spawn-kill h)))))

(defun emacs-devtools-mcp-spawn-spawn (&rest args)
  "Spawn a subordinate Emacs daemon and return its record plist.
Recognized keys in ARGS: `:init' (path; allowlist-checked),
`:headless' (boolean; not yet supported).  The server name is
always auto-generated as `edmcp-spawn-<HANDLE>' so the reaper
never touches a daemon owned by the user.  Signals
`emacs-devtools-mcp-spawn-error' on validation failure or daemon
boot timeout."
  (let* ((init (plist-get args :init))
         (headless (plist-get args :headless))
         (handle (edmcp--spawn-alloc-handle))
         (server-name (edmcp--spawn-validate-server-name
                       (edmcp--spawn-server-name-for handle))))
    (when (gethash handle emacs-devtools-mcp-spawn--handles)
      (signal 'emacs-devtools-mcp-spawn-error
              (list "handle collision (impossibly bad luck)" handle)))
    (when (>= (hash-table-count emacs-devtools-mcp-spawn--handles)
              emacs-devtools-mcp-spawn-max-handles)
      (signal 'emacs-devtools-mcp-spawn-error
              (list (format "max-handles (%d) reached"
                            emacs-devtools-mcp-spawn-max-handles))))
    (when (and headless (not (eq headless :json-false)))
      (signal 'emacs-devtools-mcp-spawn-error
              (list "headless mode not yet implemented")))
    (let* ((init-real (and init
                           (emacs-devtools-mcp-auth-validate-init-path init)))
           (extra (when init-real (list "-l" init-real)))
           (pid (edmcp--spawn-start-bg-daemon server-name extra))
           (rec (list :handle handle
                      :server-name server-name
                      :pid pid
                      :headless nil
                      :init init-real
                      :attached nil
                      :created (float-time)
                      :last-used (float-time))))
      (puthash handle rec emacs-devtools-mcp-spawn--handles)
      (edmcp--spawn-ensure-reaper)
      rec)))

(defun edmcp--spawn-find-by-server-name (server-name)
  "Return the existing handle string registered against SERVER-NAME, or nil.
Walks `emacs-devtools-mcp-spawn--handles' once.  Used by
`spawn-attach' to refuse a second registration of the same daemon
-- two handles for one daemon let an explicit kill or reaper sweep
on one strand the other against a now-dead server name."
  (let ((found nil))
    (maphash (lambda (h rec)
               (when (and (null found)
                          (equal server-name (plist-get rec :server-name)))
                 (setq found h)))
             emacs-devtools-mcp-spawn--handles)
    found))

(defun emacs-devtools-mcp-spawn-attach (server-name)
  "Register an externally-started daemon SERVER-NAME and return its record.
The server name must match `[A-Za-z0-9_-]+'.  Probes the daemon
before recording it.  Refuses to register a second handle for a
daemon already tracked under SERVER-NAME -- the server name is the
daemon's identity, and a second handle would just leave one strand
dangling against a dead server when the other is killed."
  (edmcp--spawn-validate-server-name server-name)
  (when-let ((existing (edmcp--spawn-find-by-server-name server-name)))
    (signal 'emacs-devtools-mcp-spawn-error
            (list (format "daemon %s already tracked under handle %s"
                          server-name existing))))
  (when (>= (hash-table-count emacs-devtools-mcp-spawn--handles)
            emacs-devtools-mcp-spawn-max-handles)
    (signal 'emacs-devtools-mcp-spawn-error
            (list (format "max-handles (%d) reached"
                          emacs-devtools-mcp-spawn-max-handles))))
  (let* ((pid (or (edmcp--spawn-emacsclient-ping server-name)
                  (signal 'emacs-devtools-mcp-spawn-error
                          (list (format "no daemon answered at %s"
                                        server-name)))))
         (handle (edmcp--spawn-alloc-handle))
         (rec (list :handle handle
                    :server-name server-name
                    :pid pid
                    :headless nil
                    :init nil
                    :attached t
                    :created (float-time)
                    :last-used (float-time))))
    (puthash handle rec emacs-devtools-mcp-spawn--handles)
    (edmcp--spawn-ensure-reaper)
    rec))

(defun emacs-devtools-mcp-spawn-kill (handle)
  "Drop HANDLE's record and, when not attached, kill its daemon.
Returns the dropped record with an extra `:kill-status' field:
  `attached'     -- handle was registered via `spawn-attach'; the
                    user-owned daemon is left running.
  `killed'       -- `(kill-emacs)' RPC succeeded.
  `already-dead' -- RPC failed (rc/=0); the daemon was unreachable.
The status surfaces through the public `kill_spawn' tool so a client
can tell `we never knew about it' apart from `we knew, we tried, it
was already dead'."
  (let* ((rec (edmcp--spawn-lookup handle))
         (server-name (plist-get rec :server-name))
         (status
          (cond
           ((plist-get rec :attached) 'attached)
           (t
            (let ((res (ignore-errors
                         (edmcp--spawn-call-process
                          emacs-devtools-mcp-spawn-emacsclient-program
                          (list "-s" server-name "--eval" "(kill-emacs)")))))
              (if (and (consp res) (zerop (car res)))
                  'killed
                'already-dead))))))
    (remhash handle emacs-devtools-mcp-spawn--handles)
    (plist-put rec :kill-status status)))

(defun emacs-devtools-mcp-spawn-list ()
  "Return a list of public handle plists, sorted by handle string."
  (let (out)
    (maphash (lambda (_h rec)
               (push (edmcp--spawn-record-public rec) out))
             emacs-devtools-mcp-spawn--handles)
    (sort out (lambda (a b) (string< (plist-get a :handle)
                                     (plist-get b :handle))))))

(defun emacs-devtools-mcp-spawn-kill-all ()
  "Kill every tracked handle and cancel the reaper timer."
  (let (handles)
    (maphash (lambda (h _v) (push h handles))
             emacs-devtools-mcp-spawn--handles)
    (dolist (h handles)
      (ignore-errors (emacs-devtools-mcp-spawn-kill h))))
  (when emacs-devtools-mcp-spawn--reaper-timer
    (ignore-errors (cancel-timer emacs-devtools-mcp-spawn--reaper-timer))
    (setq emacs-devtools-mcp-spawn--reaper-timer nil)))

(add-hook 'kill-emacs-hook #'emacs-devtools-mcp-spawn-kill-all)

(defconst edmcp--spawn-reader-eval-re "#\\."
  "Matches the `#.' read-time-eval reader macro in raw output.
We reject any daemon reply containing this sequence rather than
attempt to parse selectively, because Emacs's `read' has no
documented switch to inhibit `#.' evaluation.")

(defun edmcp--spawn-parse-reply (raw)
  "Parse RAW emacsclient reply text into the corresponding Lisp value.
Pre-scans for the `#.' reader macro and refuses to call `read' on
a reply that contains it.  Distinguishes truly empty input
\(\"empty reply\") from input that begins parsing but fails
\(\"unreadable\")."
  (when (string-match-p edmcp--spawn-reader-eval-re raw)
    (signal 'emacs-devtools-mcp-spawn-error
            (list "rejected `#.' in daemon reply" (string-trim raw))))
  (when (or (null raw) (string-empty-p (string-trim raw)))
    (signal 'emacs-devtools-mcp-spawn-error
            (list "empty reply from emacsclient")))
  (with-temp-buffer
    (insert raw)
    (goto-char (point-min))
    (condition-case err
        (read (current-buffer))
      (error
       (signal 'emacs-devtools-mcp-spawn-error
               (list (format "unreadable reply: %s -- raw: %s"
                             (error-message-string err)
                             (string-trim raw))))))))

(defun edmcp--spawn-emacsclient-eval (handle form)
  "Run a `read'-decoded `emacsclient --eval' for HANDLE on FORM.
HANDLE selects the daemon record; FORM is serialized via
`prin1-to-string' and passed as a single argv element to
`emacsclient' -- no shell, no quoting hazards.  The reply is
filtered through `edmcp--spawn-parse-reply' which rejects any
`#.' reader macro before calling `read'."
  (let* ((rec (edmcp--spawn-lookup handle))
         (server-name (plist-get rec :server-name))
         (form-str
          (let ((print-level nil)
                (print-length nil)
                (print-circle t)
                (print-escape-newlines t)
                (print-escape-control-characters t))
            (prin1-to-string form))))
    (let ((res (edmcp--spawn-call-process
                emacs-devtools-mcp-spawn-emacsclient-program
                (list "-s" server-name "--eval" form-str))))
      (let ((rc (car res))
            (out (cdr res)))
        (unless (zerop rc)
          (signal 'emacs-devtools-mcp-spawn-error
                  (list (format "emacsclient -s %s rc=%d: %s"
                                server-name rc (string-trim out)))))
        (edmcp--spawn-parse-reply out)))))

(defun emacs-devtools-mcp-spawn-call (target form)
  "Evaluate in TARGET the value FORM and return its result.
TARGET is nil, `(:host t)', or `(:spawn HANDLE)'.  When TARGET
selects host, FORM is evaluated lexically in the running Emacs.
When TARGET selects a spawn handle, FORM is sent to that
subordinate Emacs over `emacsclient --eval' and the reply is
parsed after pre-scanning for the `#.' reader macro."
  (cond
   ((or (null target) (plist-get target :host))
    (eval form t))
   ((stringp (plist-get target :spawn))
    (let ((handle (plist-get target :spawn)))
      (edmcp--spawn-touch handle)
      (edmcp--spawn-emacsclient-eval handle form)))
   (t
    (signal 'emacs-devtools-mcp-spawn-error
            (list "invalid target plist" target)))))

(provide 'emacs-devtools-mcp-spawn)
;;; emacs-devtools-mcp-spawn.el ends here
