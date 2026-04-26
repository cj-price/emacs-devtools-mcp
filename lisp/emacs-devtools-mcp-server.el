;;; emacs-devtools-mcp-server.el --- Unix-socket server for MCP  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; Maintainer: C.J. Price <cjprice@fastmail.com>
;; Homepage: https://github.com/cjprice/emacs-devtools-mcp
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

(defcustom emacs-devtools-mcp-slow-tool-timeout 25
  "Seconds a `:slow' tool may run before its handler is forced to error out."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-max-response-bytes (* 256 1024)
  "Hard cap on a single tool result's encoded JSON size, in bytes.
Exceeding this yields a `payload_too_large' content envelope so the
client always receives a structured error instead of a giant payload.
Image-bearing responses use `emacs-devtools-mcp-max-image-response-bytes'
instead, since base64-encoded screenshots routinely exceed 256 KiB."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-max-image-response-bytes (* 8 1024 1024)
  "Hard cap, in bytes, for tool responses that include an MCP `image' block.
A 1080p PNG screenshot at default resolution base64-encodes to
~2--3 MiB; the 256 KiB text cap would refuse those by default,
making `screenshot-frame' unusable.  Applies whenever any element
of the response's `:content' vector has `:type \"image\"'."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defcustom emacs-devtools-mcp-cursor-ttl-seconds 300
  "Seconds an unused pagination cursor token remains valid before reaping."
  :type 'natnum
  :group 'emacs-devtools-mcp-tools
  :package-version '(emacs-devtools-mcp . "0.1.0"))

(defvar emacs-devtools-mcp--cursors (make-hash-table :test 'equal)
  "Map of opaque cursor token (string) to (TIMESTAMP . CONTINUATION).
TIMESTAMP is the `float-time' value when the cursor was created.
CONTINUATION is opaque to this module: tools store and re-fetch
their own iterator state.")

(defvar emacs-devtools-mcp--tool-registry (make-hash-table :test 'equal)
  "Hash mapping snake_case tool name (string) to a record plist.
A record carries: :name, :doc, :cost, :read-only, :destructive,
:idempotent, :schema, :handler.  The handler stored here is the
post-`:slow'-wrapping function ready to call on validated params.")

(defconst emacs-devtools-mcp-target-schema
  '(:description
    "Where to run the tool.  Always an object, never a bare string.
`{\"host\": true}' (the default when omitted) routes to the user's
running Emacs -- whichever PID hosts this MCP server.  `{\"spawn\":
\"<HANDLE>\"}' routes to a subordinate Emacs previously created by
`spawn_emacs' or registered by `attach_emacs'; the handle is the
opaque string returned in those tools' results.  No other shapes
are accepted -- a string, a `{\"spawn\": true}', or a
`{\"server_name\": ...}' all fail schema validation."
    :oneOf [(:type "object"
             :properties ((host . (:const t)))
             :required ["host"]
             :description "Run on the user's Emacs (the MCP server host).")
            (:type "object"
             :properties ((spawn . (:type "string")))
             :required ["spawn"]
             :description "Run on the spawn handle returned by `spawn_emacs'/`attach_emacs'.")])
  "JSON Schema fragment shared by every tool's `target' parameter.
Splice it into a tool's :properties via the symbol -- the
schema validator handles vector arrays uniformly via
`edmcp--as-list'.")

(defvar emacs-devtools-mcp-server--process nil
  "Currently running server process, or nil.")

(defvar emacs-devtools-mcp-server--socket-path nil
  "Path of the currently bound socket, or nil.")

(defvar emacs-devtools-mcp-server--connections nil
  "List of live client RPC connections.")

(defvar emacs-devtools-mcp-server-request-dispatcher nil
  "Function called for each authenticated request.
Signature: (CONNECTION METHOD PARAMS).  Stories that add tools
populate this; nil means every authenticated request gets a JSON
RPC `-32601' (method not found).")

(defvar emacs-devtools-mcp-server-notification-dispatcher nil
  "Function called for each authenticated notification.
Signature: (CONNECTION METHOD PARAMS).  Nil = silently ignore.")

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

;;;; Tool registry + schema validator + `deftool' macro.

(defun edmcp--type-ok-p (type-name instance)
  "Return non-nil when TYPE-NAME admits INSTANCE.
TYPE-NAME is a string drawn from {string, integer, number,
boolean, null, array, object}.  INSTANCE follows the wire
mapping of `jsonrpc--json-encode' for booleans and nulls:
t / :json-false / nil."
  (pcase type-name
    ("string"  (stringp instance))
    ("integer" (integerp instance))
    ("number"  (numberp instance))
    ("boolean" (or (eq instance t) (eq instance :json-false)))
    ("null"    (null instance))
    ("array"   (vectorp instance))
    ("object"
     (or (null instance)
         (and (listp instance)
              (zerop (% (length instance) 2))
              (cl-loop for k in instance by #'cddr
                       always (keywordp k)))))
    (_ (error "Unknown JSON Schema type: %S" type-name))))

(defun edmcp--as-list (x)
  "Coerce sequence X to a list, leaving lists untouched.
JSON arrays must be vectors at the wire (so `json-serialize'
treats them as arrays rather than objects), but the validator and
docstrings think in lists.  Use this at every consumption point."
  (cond ((null x) nil)
        ((listp x) x)
        ((vectorp x) (append x nil))
        (t (list x))))

(defun edmcp--schema-types (schema)
  "Return SCHEMA's `:type' as a list of strings, or nil when absent."
  (let ((ty (plist-get schema :type)))
    (cond ((null ty) nil)
          ((stringp ty) (list ty))
          (t (edmcp--as-list ty)))))

(defun edmcp--prop-keyword (key)
  "Convert KEY from a `:properties' alist entry to a plist keyword.
KEY may be a keyword, a symbol, or a string."
  (cond ((keywordp key) key)
        ((symbolp key) (intern (concat ":" (symbol-name key))))
        ((stringp key) (intern (concat ":" key)))
        (t (signal 'wrong-type-argument (list 'symbol-or-string key)))))

(defun edmcp--prop-name (key)
  "Stringify KEY (symbol/keyword/string) for diagnostics and JSON I/O."
  (cond ((keywordp key) (substring (symbol-name key) 1))
        ((symbolp key) (symbol-name key))
        (t key)))

(defun emacs-devtools-mcp--validate (schema instance &optional path)
  "Check SCHEMA against INSTANCE at PATH.
SCHEMA is a JSON Schema subset; INSTANCE is the parsed value to
check.  PATH is the recursion accumulator -- a list of string
segments naming the location relative to the original input.
Return nil on success or `(REASON . FAILING-PATH)' on the first
failure."
  (or
   (when (plist-member schema :const)
     (let ((c (plist-get schema :const)))
       (unless (equal instance c)
         (cons (format "expected const %S, got %S" c instance) path))))
   (when (plist-member schema :enum)
     (let ((e (edmcp--as-list (plist-get schema :enum))))
       (unless (member instance e)
         (cons (format "value %S not in enum" instance) path))))
   (when (plist-member schema :oneOf)
     (let ((alts (edmcp--as-list (plist-get schema :oneOf)))
           (matched 0))
       (dolist (alt alts)
         (unless (emacs-devtools-mcp--validate alt instance path)
           (cl-incf matched)))
       (cond ((zerop matched)
              (cons "no oneOf alternative matched" path))
             ((> matched 1)
              (cons "matched multiple oneOf alternatives" path)))))
   (let ((types (edmcp--schema-types schema)))
     (when types
       (unless (cl-some (lambda (ty) (edmcp--type-ok-p ty instance)) types)
         (cons (format "expected type %S, got %S" types instance) path))))
   (when (or (member "object" (edmcp--schema-types schema))
             (plist-member schema :properties)
             (plist-member schema :required))
     (or
      (cl-some
       (lambda (req)
         (let* ((name (edmcp--prop-name req))
                (kw (edmcp--prop-keyword req)))
           (unless (plist-member instance kw)
             (cons (format "missing required property %s" name)
                   (append path (list name))))))
       (edmcp--as-list (plist-get schema :required)))
      (cl-some
       (lambda (entry)
         (let* ((name (edmcp--prop-name (car entry)))
                (kw (edmcp--prop-keyword (car entry)))
                (sub (cdr entry)))
           (when (plist-member instance kw)
             (emacs-devtools-mcp--validate sub
                                           (plist-get instance kw)
                                           (append path (list name))))))
       (plist-get schema :properties))))))

(defun emacs-devtools-mcp--tool-record (name)
  "Return the record plist for tool NAME, or nil if unregistered."
  (gethash name emacs-devtools-mcp--tool-registry))

(defun emacs-devtools-mcp--register-tool (record)
  "Register RECORD (a tool plist).  Refuse to overwrite an existing entry."
  (let ((name (plist-get record :name)))
    (when (gethash name emacs-devtools-mcp--tool-registry)
      (error "Tool already registered: %s" name))
    (puthash name record emacs-devtools-mcp--tool-registry)
    name))

(defmacro emacs-devtools-mcp-deftool (name docstring &rest body)
  "Define MCP tool NAME with DOCSTRING.
BODY is a property list with the following keys (all optional
unless noted):

  :cost          `:fast' (default) or `:slow'.  `:slow' wraps the
                 handler in `while-no-input' + `with-timeout',
                 with the deadline taken from
                 `emacs-devtools-mcp-slow-tool-timeout'.
  :read-only     boolean; surfaced as MCP `readOnlyHint'.
  :destructive   boolean; surfaced as MCP `destructiveHint'.
  :idempotent    boolean; surfaced as MCP `idempotentHint'.
  :schema        JSON Schema subset for the tool's params.
  :handler       *required* function of one argument PARAMS plist
                 returning the tool's MCP result.

The tool name on the wire is NAME with kebab-case dashes mapped
to underscores."
  (declare (indent 2) (doc-string 2))
  (let* ((cost (or (plist-get body :cost) :fast))
         (read-only (plist-get body :read-only))
         (destructive (plist-get body :destructive))
         (idempotent (plist-get body :idempotent))
         (schema (plist-get body :schema))
         (handler (plist-get body :handler))
         (name-str (symbol-name name))
         (snake (replace-regexp-in-string "-" "_" name-str))
         (slow-wrap-sym (make-symbol "edmcp-slow-result")))
    (unless handler
      (error "deftool: %s missing :handler" name))
    (unless (memq cost '(:fast :slow))
      (error "deftool: %s :cost must be :fast or :slow, got %S" name cost))
    (let ((effective
           (if (eq cost :slow)
               `(lambda (params)
                  (let ((,slow-wrap-sym
                         (while-no-input
                           (with-timeout
                               (emacs-devtools-mcp-slow-tool-timeout
                                (jsonrpc-error
                                 :code -32000
                                 :message "Tool execution timed out"))
                             (funcall ,handler params)))))
                    (when (eq ,slow-wrap-sym t)
                      (jsonrpc-error :code -32000
                                     :message "Tool execution interrupted"))
                    ,slow-wrap-sym))
             handler)))
      `(progn
         (emacs-devtools-mcp--register-tool
          (list :name ,snake
                :doc ,docstring
                :cost ,cost
                :read-only ',read-only
                :destructive ',destructive
                :idempotent ',idempotent
                :schema ,schema
                :handler ,effective))
         ',name))))

(defun edmcp--server-shutdown-soon (conn)
  "Schedule CONN to shut down after the current dispatch tick.
Lets jsonrpc.el flush a pending error reply before we close."
  (run-at-time 0 nil
               (lambda ()
                 (when (jsonrpc-running-p conn)
                   (ignore-errors (jsonrpc-shutdown conn t))))))

;;;; Pagination cursor store.

(defun emacs-devtools-mcp--cursor-token ()
  "Return a fresh 16-byte hex cursor token from `/dev/urandom'.
Not a security secret -- cursors are server-side handles guarded
by the same auth token that gates the connection -- but pulling
from a CSPRNG keeps this on the same footing as the auth token
and avoids any predictability surprise from `random'."
  (emacs-devtools-mcp-random-hex 16))

(defun emacs-devtools-mcp--cursor-cleanup ()
  "Drop expired entries from `emacs-devtools-mcp--cursors'."
  (let ((cutoff (- (float-time) emacs-devtools-mcp-cursor-ttl-seconds))
        (dead nil))
    (maphash (lambda (k v) (when (< (car v) cutoff) (push k dead)))
             emacs-devtools-mcp--cursors)
    (dolist (k dead)
      (remhash k emacs-devtools-mcp--cursors))))

(defun emacs-devtools-mcp--cursor-store (continuation)
  "Persist CONTINUATION under a fresh cursor token; return the token."
  (emacs-devtools-mcp--cursor-cleanup)
  (let ((token (emacs-devtools-mcp--cursor-token)))
    (puthash token (cons (float-time) continuation)
             emacs-devtools-mcp--cursors)
    token))

(defun emacs-devtools-mcp--cursor-fetch (token)
  "Pop CONTINUATION for TOKEN.  Return nil if missing or expired."
  (emacs-devtools-mcp--cursor-cleanup)
  (let ((entry (gethash token emacs-devtools-mcp--cursors)))
    (when entry
      (remhash token emacs-devtools-mcp--cursors)
      (cdr entry))))

(defun emacs-devtools-mcp--paginate (items page-size cursor)
  "Slice ITEMS by PAGE-SIZE under CURSOR; return (PAGE NEXT-CURSOR-OR-NIL).
ITEMS is the full list when CURSOR is nil; otherwise the cursor's
saved tail is used and ITEMS is ignored.  PAGE-SIZE is a positive
integer.  When more entries remain after the page, a fresh cursor
is allocated for the tail and returned in the second slot.

A non-nil CURSOR that misses the cursor store -- because it was
never issued, has been consumed by an earlier call, or has aged
out past `emacs-devtools-mcp-cursor-ttl-seconds' -- signals a
JSON-RPC `-32602' error rather than silently returning an empty
page.  An empty page would be indistinguishable from end-of-results
and would leave the caller convinced their iteration completed."
  (let* ((tail (if cursor
                   (or (emacs-devtools-mcp--cursor-fetch cursor)
                       (jsonrpc-error
                        :code -32602
                        :message
                        (format "Invalid or expired cursor: %S (cursors expire after %d s)"
                                cursor
                                emacs-devtools-mcp-cursor-ttl-seconds)))
                 items))
         (page (cl-subseq tail 0 (min page-size (length tail))))
         (rest (nthcdr (length page) tail))
         (next (when rest (emacs-devtools-mcp--cursor-store rest))))
    (list page next)))

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

(setq emacs-devtools-mcp-server-request-dispatcher
      #'emacs-devtools-mcp-server-default-dispatcher)

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
connection is closed.  After auth, requests are forwarded to
`emacs-devtools-mcp-server-request-dispatcher' if set, else
return `-32601' method-not-found."
  (let ((proc (edmcp--rpc-process conn)))
    (cond
     ((process-get proc 'edmcp-authenticated)
      (if emacs-devtools-mcp-server-request-dispatcher
          (funcall emacs-devtools-mcp-server-request-dispatcher
                   conn method params)
        (jsonrpc-error :code -32601
                       :message (format "Method not found: %s" method))))
     ((eq method 'initialize)
      (cond
       ((not (emacs-devtools-mcp-auth--check-peer proc))
        (emacs-devtools-mcp-auth-log-failure
         (jsonrpc-name conn) "initialize: peer rejected")
        (edmcp--server-shutdown-soon conn)
        (jsonrpc-error :code -32600 :message "auth failed"))
       (t
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
            (jsonrpc-error :code -32600 :message "auth failed"))))))
     (t
      (emacs-devtools-mcp-auth-log-failure
       (jsonrpc-name conn) (format "%s before initialize" method))
      (edmcp--server-shutdown-soon conn)
      (jsonrpc-error :code -32600
                     :message "must initialize first")))))

(defun edmcp--server-handle-notification (conn method params)
  "Auth-gated notification dispatcher for CONN.
METHOD is a symbol; PARAMS a plist.  Drops anything received
before authentication and closes the connection (per AC: any
non-initialize first frame is rejected).  After auth, forwards to
`emacs-devtools-mcp-server-notification-dispatcher' if set."
  (let ((proc (edmcp--rpc-process conn)))
    (cond
     ((process-get proc 'edmcp-authenticated)
      (when emacs-devtools-mcp-server-notification-dispatcher
        (funcall emacs-devtools-mcp-server-notification-dispatcher
                 conn method params)))
     (t
      (emacs-devtools-mcp-auth-log-failure
       (jsonrpc-name conn)
       (format "notification %s before initialize" method))
      (edmcp--server-shutdown-soon conn)))))

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
