;;; emacs-devtools-mcp.el --- Devtools MCP server for Emacs  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  cj-price
;; Homepage: https://github.com/cj-price/emacs-devtools-mcp
;; Keywords: tools, convenience
;; Package-Version: 0.1.4
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Package entry point.  Holds the customization groups, the tool
;; registry, the `emacs-devtools-mcp-deftool' macro, the JSON Schema
;; validator, the pagination cursor store, the shared
;; `emacs-devtools-mcp-target-schema' constant, the
;; `emacs-devtools-mcp-random-hex' entropy helper (shared by the
;; cursor store and the auth subsystem), and the
;; `emacs-devtools-mcp--load-tools' helper that requires every
;; `tools-<domain>' file on demand.  Transport
;; (`emacs-devtools-mcp-server') and tool subsystems
;; (`emacs-devtools-mcp-tools-<domain>') depend on this file; this
;; file depends on no other package file, so the dependency graph is
;; a DAG with the umbrella at the root.

;;; Code:

;; Internal short alias: edmcp-- (this file only).

(require 'cl-lib)
(require 'jsonrpc)

(defconst emacs-devtools-mcp-version "0.1.4"
  "Current version of the `emacs-devtools-mcp' package.
Must match the `Package-Version' header of this file; a `:fast'
ERT test enforces the pairing so the release tag, the header, and
the `serverInfo' version advertised in `initialize' cannot drift.")

(defgroup emacs-devtools-mcp nil
  "Devtools MCP server for Emacs."
  :group 'tools
  :prefix "emacs-devtools-mcp-"
  :link '(url-link :tag "Homepage"
                   "https://github.com/cj-price/emacs-devtools-mcp"))

(defgroup emacs-devtools-mcp-server nil
  "Transport, dispatch, and lifecycle for the MCP server."
  :group 'emacs-devtools-mcp
  :prefix "emacs-devtools-mcp-")

(defgroup emacs-devtools-mcp-spawn nil
  "Subordinate Emacs lifecycle for the spawn target."
  :group 'emacs-devtools-mcp
  :prefix "emacs-devtools-mcp-spawn-")

(defgroup emacs-devtools-mcp-tools nil
  "Per-category tool defaults."
  :group 'emacs-devtools-mcp
  :prefix "emacs-devtools-mcp-")

(defgroup emacs-devtools-mcp-security nil
  "Authentication, redaction, and allowlist policy."
  :group 'emacs-devtools-mcp
  :prefix "emacs-devtools-mcp-")

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
Splice it into a tool's `:properties' alist with backquote-comma
syntax, e.g. `(target . ,emacs-devtools-mcp-target-schema), so
every tool advertises the same canonical host/spawn `:oneOf'
shape.  The validator handles vector arrays uniformly via
`edmcp--as-list'.")

(defconst emacs-devtools-mcp-unsafe-reader-re "#\\(?:[.@]\\|[0-9]+[=#]\\)"
  "Matches the reader syntax refused before any `read' of untrusted text.
Shared by every scanner that guards a `read' call: the spawn-reply
parser in `emacs-devtools-mcp-spawn', the agent-supplied predicate
and probe-output scans in `emacs-devtools-mcp-tools-init', and the
ert selector scan in `emacs-devtools-mcp-tools-buffer'.  One
constant, so the rejected set cannot drift between read sites.

Three constructs are rejected:

`#.' is the load-bearing case: it is read-time `eval', and Emacs
`read' has no documented switch to inhibit it, so scanned text
carrying `#.' could execute code in the host.

`#@COUNT' (skip COUNT characters) executes nothing, but is
rejected as defense-in-depth against input desynchronizing the
reader.

`#N='/`#N#' reader labels are the only way `read' can build a
shared or circular structure; without them the parsed value is a
tree whose printed and JSON-serialized size is linear in the
input.  A labeled DAG instead expands ~2^N, so a sub-kilobyte
input could blow up `json-serialize' (success path) or
`error-message-string' (error path) and exhaust host memory.
Rejecting the labels closes that amplifier at the source; the
bounded error printing in `emacs-devtools-mcp-server' remains as
a backstop.

Byte-code literals (`#[') still pass -- they are never funcalled
by any consumer and `json-serialize' refuses them outright, so
they reach only the (bounded) error path, not an amplifier.  The
scan is position-blind: the rare input whose printed value merely
contains one of these sequences inside a string is rejected
rather than parsed selectively.")

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
                           ;; Cons-wrap the handler's value: a handler
                           ;; legitimately returning t would otherwise be
                           ;; indistinguishable from `while-no-input's
                           ;; input-arrived sentinel (literal t).
                           (cons 'value
                                 (with-timeout
                                     (emacs-devtools-mcp-slow-tool-timeout
                                      (jsonrpc-error
                                       :code -32000
                                       :message "Tool execution timed out"))
                                   (funcall ,handler params))))))
                    (if (eq ,slow-wrap-sym t)
                        (jsonrpc-error :code -32000
                                       :message "Tool execution interrupted")
                      (cdr ,slow-wrap-sym))))
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

;;;; Pagination cursor store.

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
  (let ((token (emacs-devtools-mcp-random-hex 16)))
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

(defun emacs-devtools-mcp--load-tools ()
  "Require every tool subsystem.
Tool files are not auto-loaded by `(require \\='emacs-devtools-mcp)'
because that would force every consumer of the umbrella to pay for
loading every tool subsystem regardless of whether they ever start
the server.  `emacs-devtools-mcp-server-start' and the spawn
bootstrap argv each call this helper at the moment they actually
need tools registered."
  (require 'emacs-devtools-mcp-tools-eval)
  (require 'emacs-devtools-mcp-tools-buffer)
  (require 'emacs-devtools-mcp-tools-keys)
  (require 'emacs-devtools-mcp-tools-gui)
  (require 'emacs-devtools-mcp-tools-spawn)
  (require 'emacs-devtools-mcp-tools-init))

(provide 'emacs-devtools-mcp)
;;; emacs-devtools-mcp.el ends here
