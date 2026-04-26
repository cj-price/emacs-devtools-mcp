;;; emacs-devtools-mcp-rpc.el --- Newline-framed JSON-RPC for MCP  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A `jsonrpc-connection' subclass that frames messages as newline
;; delimited JSON, per the Model Context Protocol stdio specification.
;; Built-in `jsonrpc-process-connection' uses Content-Length headers
;; (LSP-style) and is therefore unsuitable for MCP.  We keep the
;; abstract dispatch / continuation / events-buffer machinery from
;; `jsonrpc.el' and replace the framing only.
;;
;; The class is transport-agnostic: any process whose stdout yields
;; newline-delimited UTF-8 JSON and whose stdin accepts the same is
;; supported.  Higher layers wrap a Unix-domain socket; tests use
;; pipes.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'eieio)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)

(define-error 'emacs-devtools-mcp-rpc-error
  "MCP framing or transport error"
  'jsonrpc-error)

(defun emacs-devtools-mcp-random-hex (n-bytes)
  "Return a hex string of N-BYTES bytes drawn from `/dev/urandom'.
Used for both the per-launch auth token and pagination cursor
identifiers.  Reads through `head -c N-BYTES /dev/urandom' because
`insert-file-contents-literally' silently returns zero bytes on
character devices when given a BEG/END range.  Falls back silently
to `random' only if the subprocess fails or returns short -- on
Linux/BSD/macOS the primary path always succeeds, and the
fallback is correctness-equivalent (only the entropy source
weakens), so a *Warnings* entry on every fallback was pure noise."
  (or (ignore-errors
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (let* ((default-directory "/")
                 (rc (call-process "head" nil (list (current-buffer) nil) nil
                                   "-c" (number-to-string n-bytes)
                                   "/dev/urandom"))
                 (bytes (buffer-string)))
            (when (and (eq rc 0) (= (length bytes) n-bytes))
              (mapconcat (lambda (b) (format "%02x" b)) bytes "")))))
      (let ((s (make-string n-bytes 0)))
        (dotimes (i n-bytes) (aset s i (random 256)))
        (mapconcat (lambda (b) (format "%02x" b)) s ""))))

(defconst emacs-devtools-mcp--default-redact-regexps
  '("^[ \t(]*auth-source-"
    "^[ \t(]*epg-"
    "^[ \t(]*tramp-")
  "Built-in line-match patterns dropped before output reaches the wire.
These targets are commonly a source of secrets or noisy debug
output.  Patterns require the prefix to be the first significant
token on the line, modulo leading whitespace and an optional open
paren -- so `auth-source-search: ...' is scrubbed,
`(auth-source-search ...)' is scrubbed, and a backtrace frame
`  (auth-source-search ...)' is scrubbed.  A line that merely
mentions one of the prefixes mid-token, e.g.\\ a frame named
`my-pkg-call-auth-source-foo', passes through.  Customize via
`emacs-devtools-mcp-redact-extra-regexps' to add project-specific
patterns; you cannot disable the default set by design.")

(defcustom emacs-devtools-mcp-redact-extra-regexps nil
  "Additional regexps whose matching lines are stripped from text output.
The defaults in `emacs-devtools-mcp--default-redact-regexps'
always apply; this is purely additive."
  :type '(repeat regexp)
  :group 'emacs-devtools-mcp-security
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defun emacs-devtools-mcp-redact (string)
  "Return STRING with lines matching any redaction regexp removed.
Lines are LF-delimited; trailing blank lines are preserved.  Pass
this around any *Messages*, backtrace, or process-output capture
before it leaves the host."
  (if (or (null string) (string-empty-p string))
      string
    (let* ((patterns (append emacs-devtools-mcp--default-redact-regexps
                             emacs-devtools-mcp-redact-extra-regexps))
           (re (mapconcat (lambda (p) (concat "\\(?:" p "\\)"))
                          patterns "\\|"))
           (kept nil))
      (dolist (line (split-string string "\n"))
        (unless (string-match-p re line)
          (push line kept)))
      (mapconcat #'identity (nreverse kept) "\n"))))

(defclass emacs-devtools-mcp-rpc-connection (jsonrpc-connection)
  ((-process
    :initarg :process
    :accessor edmcp--rpc-process
    :documentation "Underlying process whose stdio carries the framed JSON.")
   (-on-shutdown
    :initarg :on-shutdown
    :initform #'ignore
    :accessor edmcp--rpc-on-shutdown
    :documentation "Function of one argument called when the process dies."))
  :documentation "A `jsonrpc-connection' framed as `<json>\\n' per MCP stdio.
Initargs:

:PROCESS (mandatory) -- a live process whose stdin we write to and
whose stdout filter we own.

:ON-SHUTDOWN (optional) -- a function of one argument (this
connection) called from the sentinel when the process dies.")

(cl-defmethod initialize-instance :after
  ((conn emacs-devtools-mcp-rpc-connection) slots)
  "Wire CONN's process: own filter, sentinel, output buffer, coding system.
SLOTS is the initarg plist supplied to `make-instance'."
  (cl-destructuring-bind (&key ((:process proc)) name &allow-other-keys) slots
    (unless (processp proc)
      (signal 'emacs-devtools-mcp-rpc-error
              (list ":process must be a live process object")))
    (setf (edmcp--rpc-process conn) proc)
    (set-process-buffer proc
                        (get-buffer-create
                         (format " *%s output*" (or name "edmcp-rpc"))))
    (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)
    (set-process-filter proc #'edmcp--rpc-process-filter)
    (set-process-sentinel proc #'edmcp--rpc-process-sentinel)
    (with-current-buffer (process-buffer proc)
      (buffer-disable-undo)
      (let ((inhibit-read-only t)) (erase-buffer))
      (set-marker (process-mark proc) (point-min))
      (setq buffer-read-only t))
    (process-put proc 'jsonrpc-connection conn)))

(cl-defmethod jsonrpc-connection-send
  ((connection emacs-devtools-mcp-rpc-connection)
   &rest args
   &key id method _params (_result nil result-supplied-p) error _partial)
  "Encode and write one MCP frame to CONNECTION.
The keyword ARGS follow the `jsonrpc-connection-send' generic.
Keys interpreted directly here are ID, METHOD, RESULT, and ERROR --
the rest reach the wire via `jsonrpc-convert-to-endpoint'."
  (when method
    (setq args
          (plist-put args :method
                     (cond ((keywordp method)
                            (substring (symbol-name method) 1))
                           ((symbolp method) (symbol-name method))
                           ((stringp method) method)
                           (t (signal 'emacs-devtools-mcp-rpc-error
                                      (list (format "invalid method %S"
                                                    method))))))))
  (let* ((kind (cond ((or result-supplied-p error) 'reply)
                     (id 'request)
                     (method 'notification)))
         (converted (jsonrpc-convert-to-endpoint connection args kind))
         (json (jsonrpc--json-encode converted)))
    (when (string-search "\n" json)
      (signal 'emacs-devtools-mcp-rpc-error
              (list "MCP framing forbids embedded LF in encoded JSON" json)))
    (process-send-string (edmcp--rpc-process connection)
                         (concat json "\n"))
    (jsonrpc--event connection 'client
                    :json json
                    :kind kind
                    :message args
                    :foreign-message converted)))

(cl-defmethod jsonrpc-running-p
  ((conn emacs-devtools-mcp-rpc-connection))
  "Return non-nil when CONN's underlying process is still live."
  (let ((proc (edmcp--rpc-process conn)))
    (and proc (process-live-p proc))))

(cl-defmethod jsonrpc-shutdown
  ((conn emacs-devtools-mcp-rpc-connection) &optional cleanup)
  "Tear down CONN, deleting its process.
With non-nil CLEANUP, also kill the process buffer."
  (let ((proc (edmcp--rpc-process conn)))
    (when (and proc (process-live-p proc))
      (delete-process proc))
    (when (and cleanup proc (buffer-live-p (process-buffer proc)))
      (kill-buffer (process-buffer proc)))))

(defun edmcp--rpc-process-sentinel (proc _change)
  "Sentinel for the underlying PROC of an MCP RPC connection.
Cancels outstanding continuations and runs the connection's
`-on-shutdown' callback when PROC exits.  _CHANGE is unused."
  (when (and (not (process-live-p proc))
             (process-get proc 'jsonrpc-connection))
    (let ((conn (process-get proc 'jsonrpc-connection)))
      (mapc (lambda (cont)
              (pcase-let ((`(,_id ,_method ,_succ ,error-fn ,timer) cont))
                (when timer (cancel-timer timer))
                (when error-fn
                  (ignore-errors
                    (funcall error-fn
                             (list :code -1
                                   :message "Connection died"))))))
            (jsonrpc--continuations conn))
      (setf (jsonrpc--continuations conn) nil)
      (ignore-errors
        (funcall (edmcp--rpc-on-shutdown conn) conn)))))

(defun edmcp--rpc-process-filter (proc string)
  "Process filter for an MCP RPC connection.
PROC is the underlying process and STRING is the freshly received
chunk.  Append STRING to PROC's output buffer, then dispatch every
complete `<json>\\n' frame.  Empty lines are silently skipped.
Lines that fail to parse are logged via `jsonrpc--warn' and
discarded; partial lines are buffered until the next call."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((conn (process-get proc 'jsonrpc-connection))
            (inhibit-read-only t)
            (messages nil))
        (save-excursion
          (goto-char (process-mark proc))
          (insert string)
          (set-marker (process-mark proc) (point)))
        (goto-char (point-min))
        (while (let ((nl (search-forward "\n" (process-mark proc) t)))
                 (when nl
                   (let* ((line-end (1- nl))
                          (line-start (point-min))
                          (raw (buffer-substring-no-properties
                                line-start line-end)))
                     (delete-region line-start nl)
                     (goto-char (point-min))
                     (unless (string-empty-p raw)
                       (let ((parsed
                              (condition-case oops
                                  (with-temp-buffer
                                    (insert raw)
                                    (goto-char (point-min))
                                    (jsonrpc--json-read))
                                (error
                                 (jsonrpc--warn
                                  "Invalid JSON frame discarded: %s %s"
                                  (cdr oops) raw)
                                 nil))))
                         (when parsed
                           (push (plist-put parsed :jsonrpc-json raw)
                                 messages))))
                     t))))
        (when conn
          (dolist (msg (nreverse messages))
            (with-temp-buffer
              (jsonrpc-connection-receive conn msg))))))))

(provide 'emacs-devtools-mcp-rpc)
;;; emacs-devtools-mcp-rpc.el ends here
