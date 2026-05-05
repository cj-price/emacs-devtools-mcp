;;; emacs-devtools-mcp-server.el --- Unix-socket server for MCP  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  cj-price
;; Homepage: https://github.com/cj-price/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Listens on a Unix-domain socket at
;; `${XDG_RUNTIME_DIR}/edmcp/${NAME}.sock'.  Each accepted connection
;; is wrapped in an `emacs-devtools-mcp-rpc-connection' (story 003).
;; Hard-fails if `XDG_RUNTIME_DIR' is unset; never falls back to
;; `/tmp'.  Refuses to bind on top of a non-socket file, a symlink, or
;; a path owned by another uid.  Unlinks a stale socket (S_ISSOCK +
;; same uid) and rebinds.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'seq)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-auth)

(defcustom emacs-devtools-mcp-server-name "default"
  "Slug used in the socket file name.
The socket lives at `$XDG_RUNTIME_DIR/edmcp/<NAME>.sock'.  Use a
different value to run two host Emacsen for the same user without
collision."
  :type 'string
  :group 'emacs-devtools-mcp-server
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defvar emacs-devtools-mcp-server--process nil
  "Currently running server process, or nil.")

(defvar emacs-devtools-mcp-server--socket-path nil
  "Path of the currently bound socket, or nil.")

(defvar emacs-devtools-mcp-server--connections nil
  "List of live client RPC connections.")

(defconst emacs-devtools-mcp-server--protocol-version "2024-11-05"
  "MCP protocol version we advertise in the `initialize' result.")

(defun edmcp--server-runtime-dir ()
  "Return `XDG_RUNTIME_DIR', or signal `user-error' if unset."
  (or (getenv "XDG_RUNTIME_DIR")
      (user-error
       "XDG_RUNTIME_DIR is unset; refusing to fall back to /tmp")))

(defun edmcp--server-socket-dir ()
  "Return the per-user MCP socket directory path (with trailing slash)."
  (file-name-as-directory
   (expand-file-name "edmcp" (edmcp--server-runtime-dir))))

(defun edmcp--server-socket-path (&optional name)
  "Return the full socket path for NAME (defaults to the configured slug)."
  (expand-file-name (concat (or name emacs-devtools-mcp-server-name) ".sock")
                    (edmcp--server-socket-dir)))

(defun edmcp--server-ensure-dir ()
  "Create the socket directory if absent and enforce mode 0700."
  (let ((dir (edmcp--server-socket-dir)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (set-file-modes dir #o700)
    dir))

(defun edmcp--server-validate-or-unlink (path)
  "Validate any pre-existing PATH; unlink a stale socket; signal on hostile state."
  (when (file-exists-p path)
    (when (file-symlink-p path)
      (user-error "Refusing to bind: %s is a symlink" path))
    (let* ((attrs (file-attributes path 'integer))
           (uid (and attrs (file-attribute-user-id attrs)))
           (modes (and attrs (file-attribute-modes attrs))))
      (unless attrs
        (user-error "Cannot stat %s" path))
      (unless (= uid (user-uid))
        (user-error "Refusing to bind: %s owned by uid %d, not %d"
                    path uid (user-uid)))
      (unless (and modes (eq (aref modes 0) ?s))
        (user-error "Refusing to bind: %s exists and is not a socket" path))
      (delete-file path))))

(defun edmcp--server-shutdown-soon (conn)
  "Schedule CONN to shut down after the current dispatch tick.
Lets jsonrpc.el flush a pending error reply before we close."
  (run-at-time 0 nil
               (lambda ()
                 (when (jsonrpc-running-p conn)
                   (ignore-errors (jsonrpc-shutdown conn t))))))

;;;; tools/list, tools/call, and the built-in `ping' smoke tool.

(defun edmcp--server-tools-list-entry (rec)
  "Build a single `tools/list' entry plist from registry RECORD REC."
  (let ((annot nil))
    (when (plist-get rec :read-only)
      (setq annot (plist-put annot :readOnlyHint t)))
    (when (plist-get rec :destructive)
      (setq annot (plist-put annot :destructiveHint t)))
    (when (plist-get rec :idempotent)
      (setq annot (plist-put annot :idempotentHint t)))
    (let ((entry (list :name (plist-get rec :name)
                       :description (plist-get rec :doc)
                       :inputSchema (or (plist-get rec :schema)
                                        '(:type "object")))))
      (when annot
        (setq entry (plist-put entry :annotations annot)))
      entry)))

(defun edmcp--server-tools-list (_params)
  "Build the `tools/list' result.
Tools are emitted in alphabetical name order so the wire format
is deterministic for tests and human eyeballing."
  (let (names)
    (maphash (lambda (k _v) (push k names))
             emacs-devtools-mcp--tool-registry)
    (setq names (sort names #'string<))
    (list :tools
          (vconcat
           (mapcar (lambda (n)
                     (edmcp--server-tools-list-entry
                      (gethash n emacs-devtools-mcp--tool-registry)))
                   names)))))

(defun edmcp--server-wrap-content (result)
  "Coerce tool RESULT into an MCP `tools/call' content block envelope.
A string becomes a single text block; a plist that already carries
`:content' is returned with `:isError :json-false' filled in if
absent; anything else is JSON-encoded into a text block so the
client receives structured data even when the tool is terse.

`jsonrpc--json-encode' returns a unibyte UTF-8 byte string; embed
it as multibyte text so the surrounding envelope can itself be
re-encoded by `json-serialize' (which rejects unibyte strings)."
  (cond
   ((stringp result)
    (list :content
          (vector (list :type "text" :text result))
          :isError :json-false))
   ((and (listp result) (plist-member result :content))
    (if (plist-member result :isError)
        result
      (plist-put result :isError :json-false)))
   (t
    (list :content
          (vector (list :type "text"
                        :text (decode-coding-string
                               (jsonrpc--json-encode result)
                               'utf-8)))
          :isError :json-false))))

(defun edmcp--server-envelope-has-image-p (envelope)
  "Return non-nil if ENVELOPE's `:content' vector includes an image block.
An image block is any element whose `:type' is the string
`image' -- the standard MCP content block for binary data."
  (let ((content (plist-get envelope :content)))
    (and (vectorp content)
         (seq-some (lambda (block)
                     (and (listp block)
                          (equal (plist-get block :type) "image")))
                   content))))

(defun edmcp--server-response-cap (envelope)
  "Return the byte cap to apply to ENVELOPE.
Image-bearing envelopes use the larger image cap; everything else
uses the standard response cap."
  (if (edmcp--server-envelope-has-image-p envelope)
      emacs-devtools-mcp-max-image-response-bytes
    emacs-devtools-mcp-max-response-bytes))

(defun edmcp--server-too-large-p (envelope)
  "Return non-nil if ENVELOPE's encoded form exceeds its applicable cap."
  (> (string-bytes (jsonrpc--json-encode envelope))
     (edmcp--server-response-cap envelope)))

(defun edmcp--server-payload-too-large-envelope (cap)
  "Return the canonical `payload_too_large' tool-result envelope.
CAP is the byte cap that the over-cap envelope exceeded; it is
formatted into the human-readable error text so an agent can see
which cap (text or image) it tripped."
  (list :content
        (vector
         (list :type "text"
               :text (format "payload_too_large: result exceeds %d bytes"
                             cap)))
        :isError t))

(defun edmcp--server-tools-call (_conn params)
  "Handle a `tools/call' request, validating PARAMS against the schema.
Unknown tool yields `-32601'; schema-invalid arguments yield
`-32602'.  Tool-execution failures (signals raised by the
handler) are returned as a success reply with `isError: t' and a
text content block carrying the error message -- never as a
JSON-RPC error code."
  (let* ((name (plist-get params :name))
         (args (plist-get params :arguments))
         (rec (gethash name emacs-devtools-mcp--tool-registry)))
    (cond
     ((null rec)
      (jsonrpc-error :code -32601
                     :message (format "Unknown tool: %s" name)))
     (t
      (let ((fail (and (plist-get rec :schema)
                       (emacs-devtools-mcp--validate
                        (plist-get rec :schema) args))))
        (when fail
          (jsonrpc-error
           :code -32602
           :message (format "Invalid params: %s%s"
                            (car fail)
                            (if (cdr fail)
                                (format " at %s"
                                        (mapconcat #'identity
                                                   (cdr fail) "."))
                              ""))))
        (let ((envelope
               (condition-case err
                   (edmcp--server-wrap-content
                    (funcall (plist-get rec :handler) args))
                 (jsonrpc-error
                  ;; Re-raise: caller framework turns this into a
                  ;; JSON-RPC error reply.  Used for protocol-level
                  ;; conditions the handler synthesizes deliberately
                  ;; (e.g. the slow-tool timeout from `deftool').
                  (signal (car err) (cdr err)))
                 (quit
                  ;; A `:slow' tool wraps its body in `while-no-input',
                  ;; which raises `quit' when the user types
                  ;; mid-handler.  Without an explicit clause `quit'
                  ;; would unwind past `tools/call' entirely, leaving
                  ;; the in-flight request without a reply -- the
                  ;; caller times out instead of getting a structured
                  ;; `cancelled' envelope.
                  (ignore err)
                  (list :content
                        (vector (list :type "text"
                                      :text "tool cancelled"))
                        :isError t))
                 (error
                  (list :content
                        (vector (list :type "text"
                                      :text (error-message-string err)))
                        :isError t)))))
          (if (edmcp--server-too-large-p envelope)
              (edmcp--server-payload-too-large-envelope
               (edmcp--server-response-cap envelope))
            envelope)))))))

(defun emacs-devtools-mcp-server-default-dispatcher (conn method params)
  "Built-in post-auth dispatcher.
CONN is the RPC connection; METHOD is a symbol; PARAMS a plist.
Recognized methods: `tools/list', `tools/call'.  Anything else
returns `-32601' method-not-found."
  (pcase method
    ('tools/list (edmcp--server-tools-list params))
    ('tools/call (edmcp--server-tools-call conn params))
    (_ (jsonrpc-error :code -32601
                      :message (format "Method not found: %s" method)))))

(emacs-devtools-mcp-deftool ping
    "Smoke-test tool: replies with \"pong\".
Accepts an optional `message' string and includes it verbatim in
the reply."
  :cost :fast
  :read-only t
  :idempotent t
  :schema `(:type "object"
            :properties ((message . (:type "string"))))
  :handler (lambda (params)
             (let ((m (and params (plist-get params :message))))
               (if m (format "pong: %s" m) "pong"))))

(defun edmcp--server-handle-request (conn method params)
  "Auth-gated request dispatcher for CONN.
METHOD is a symbol; PARAMS a plist.  Until the connection is
authenticated, only `initialize' with a matching `_meta.token' is
accepted; everything else gets a JSON-RPC error and the
connection is closed."
  (let ((proc (edmcp--rpc-process conn)))
    (cond
     ((process-get proc 'edmcp-authenticated)
      (emacs-devtools-mcp-server-default-dispatcher conn method params))
     ((eq method 'initialize)
      (let* ((meta (plist-get params :_meta))
             (token (and meta (plist-get meta :token))))
        (if (emacs-devtools-mcp-auth--check-token token)
            (progn
              (process-put proc 'edmcp-authenticated t)
              (list :protocolVersion
                    emacs-devtools-mcp-server--protocol-version
                    :serverInfo
                    (list :name "emacs-devtools-mcp"
                          :version emacs-devtools-mcp-version)
                    :capabilities
                    (list :tools (list :listChanged :json-false))))
          (emacs-devtools-mcp-auth-log-failure
           (jsonrpc-name conn) "initialize: token mismatch")
          (edmcp--server-shutdown-soon conn)
          (jsonrpc-error :code -32600 :message "auth failed"))))
     (t
      (emacs-devtools-mcp-auth-log-failure
       (jsonrpc-name conn) (format "%s before initialize" method))
      (edmcp--server-shutdown-soon conn)
      (jsonrpc-error :code -32600
                     :message "must initialize first")))))

(defun edmcp--server-handle-notification (conn method _params)
  "Auth-gated notification dispatcher for CONN.
METHOD is a symbol; _PARAMS is unused (no notifications are
acted upon today).  Drops anything received before authentication
and closes the connection (per AC: any non-initialize first frame
is rejected).  After auth, notifications are silently ignored."
  (let ((proc (edmcp--rpc-process conn)))
    (unless (process-get proc 'edmcp-authenticated)
      (emacs-devtools-mcp-auth-log-failure
       (jsonrpc-name conn)
       (format "notification %s before initialize" method))
      (edmcp--server-shutdown-soon conn))))

(defun edmcp--server-on-accept (server child _message)
  "Accept hook for SERVER.  Wrap CHILD in an auth-gated RPC connection.
The third argument _MESSAGE is unused."
  (let* ((conn-name (format "%s<%s>"
                            (process-name server)
                            (process-name child)))
         (conn
          (make-instance
           'emacs-devtools-mcp-rpc-connection
           :name conn-name
           :process child
           :request-dispatcher #'edmcp--server-handle-request
           :notification-dispatcher #'edmcp--server-handle-notification
           :on-shutdown
           (lambda (c)
             (setq emacs-devtools-mcp-server--connections
                   (delq c emacs-devtools-mcp-server--connections))))))
    (push conn emacs-devtools-mcp-server--connections)
    conn))

;;;###autoload
(defun emacs-devtools-mcp-server-start (&optional name)
  "Start the MCP server listening on a Unix-domain socket.
NAME defaults to `emacs-devtools-mcp-server-name' and selects the
socket file under `$XDG_RUNTIME_DIR/edmcp/'.  Calling while the
server is already running is a no-op and returns the existing
process object."
  (interactive)
  (if (and emacs-devtools-mcp-server--process
           (process-live-p emacs-devtools-mcp-server--process))
      emacs-devtools-mcp-server--process
    (emacs-devtools-mcp--load-tools)
    (edmcp--server-ensure-dir)
    (let ((path (edmcp--server-socket-path name)))
      (edmcp--server-validate-or-unlink path)
      ;; `with-file-modes' sets the umask so the socket created by
      ;; `make-network-process' is bound at 0600 atomically.  The
      ;; explicit `set-file-modes' on success is belt-and-suspenders
      ;; for any libc/Emacs combo that doesn't honor umask on bind.
      (let ((proc (with-file-modes #o600
                    (make-network-process
                     :name "emacs-devtools-mcp"
                     :family 'local
                     :server t
                     :service path
                     :coding 'utf-8-unix
                     :noquery t
                     :log #'edmcp--server-on-accept)))
            (success nil))
        (unwind-protect
            (progn
              (set-file-modes path #o600)
              (emacs-devtools-mcp-auth-rotate path)
              (setq emacs-devtools-mcp-server--process proc
                    emacs-devtools-mcp-server--socket-path path)
              (add-hook 'kill-emacs-hook #'emacs-devtools-mcp-server-stop)
              (setq success t)
              proc)
          (unless success
            (when (process-live-p proc)
              (delete-process proc))
            (when (file-exists-p path)
              (ignore-errors (delete-file path)))
            (emacs-devtools-mcp-auth-clear)))))))

;;;###autoload
(defun emacs-devtools-mcp-server-stop ()
  "Stop the MCP server and remove its socket file.  Idempotent."
  (interactive)
  (dolist (c emacs-devtools-mcp-server--connections)
    (ignore-errors (jsonrpc-shutdown c)))
  (setq emacs-devtools-mcp-server--connections nil)
  (when (and emacs-devtools-mcp-server--process
             (process-live-p emacs-devtools-mcp-server--process))
    (delete-process emacs-devtools-mcp-server--process))
  (setq emacs-devtools-mcp-server--process nil)
  (when emacs-devtools-mcp-server--socket-path
    (let ((path emacs-devtools-mcp-server--socket-path))
      (when (file-exists-p path)
        (ignore-errors (delete-file path)))
      (setq emacs-devtools-mcp-server--socket-path nil)))
  (emacs-devtools-mcp-auth-clear)
  (remove-hook 'kill-emacs-hook #'emacs-devtools-mcp-server-stop)
  nil)

(provide 'emacs-devtools-mcp-server)
;;; emacs-devtools-mcp-server.el ends here
