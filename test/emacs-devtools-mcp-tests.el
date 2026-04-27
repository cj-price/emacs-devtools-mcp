;;; emacs-devtools-mcp-tests.el --- Behavior tests  -*- lexical-binding:t; coding:utf-8 -*-

;; Copyright (C) 2026  C.J. Price
;; Author: C.J. Price <cjprice@fastmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Behavior-organized tests for `emacs-devtools-mcp'.  Section banners
;; (Server, RPC, Spawn, GUI, Keys, Eval, Init, Buffer) appear as
;; tools land.  Tag every test with one of `:fast', `:daemon',
;; `:fresh-daemon', `:gui'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'jsonrpc)
(require 'emacs-devtools-mcp)
(require 'emacs-devtools-mcp-rpc)
(require 'emacs-devtools-mcp-server)
(require 'emacs-devtools-mcp-auth)
(require 'emacs-devtools-mcp-spawn)
(require 'emacs-devtools-mcp-tools-eval)
(require 'emacs-devtools-mcp-tools-buffer)
(require 'emacs-devtools-mcp-tools-keys)
(require 'emacs-devtools-mcp-tools-gui)
(require 'emacs-devtools-mcp-tools-spawn)
(require 'emacs-devtools-mcp-tools-init)

;;;; ___Scaffolding___

(ert-deftest emacs-devtools-mcp-tests/version-is-a-string ()
  "Version constant exists and is a non-empty string."
  :tags '(:fast)
  (should (stringp emacs-devtools-mcp-version))
  (should (> (length emacs-devtools-mcp-version) 0)))

(ert-deftest emacs-devtools-mcp-tests/group-is-defined ()
  "Customization group is registered with the documented subgroups."
  :tags '(:fast)
  (should (get 'emacs-devtools-mcp 'group-documentation))
  (let ((children (mapcar #'car (get 'emacs-devtools-mcp 'custom-group))))
    (dolist (sub '(emacs-devtools-mcp-server
                   emacs-devtools-mcp-spawn
                   emacs-devtools-mcp-tools
                   emacs-devtools-mcp-security))
      (should (memq sub children)))))

;;;; ___RPC___
;;
;; Newline-framed JSON-RPC connection.  These tests pin down the framing
;; contract from story 003: every frame is `<json>\n', empty lines are
;; ignored, partial lines are buffered, and embedded LF in encoded JSON
;; is refused before any byte hits the wire.

(defvar emacs-devtools-mcp-tests--rpc-sent nil
  "Capture buffer for `process-send-string' during RPC framing tests.
Each entry is the exact string passed to `process-send-string'.")

(defvar emacs-devtools-mcp-tests--rpc-received nil
  "Capture buffer for messages dispatched to test connections.
Each entry is a plist of (METHOD ID PARAMS RESULT ERROR).")

(defun emacs-devtools-mcp-tests--rpc-make-process ()
  "Return a live, idle process suitable for an MCP RPC connection.
We use `make-pipe-process' (no subprocess) so the process is real
enough for `set-process-filter' / `process-live-p' but does not
spend any CPU.  Caller must `delete-process' it."
  (make-pipe-process :name "edmcp-rpc-test"
                     :buffer nil
                     :coding 'utf-8-unix
                     :noquery t))

(defmacro emacs-devtools-mcp-tests--with-rpc (binding &rest body)
  "Bind a fresh `emacs-devtools-mcp-rpc-connection' and run BODY.
BINDING is a list (VAR &key REQUEST-FN NOTIFICATION-FN).  Sent
bytes are captured into `emacs-devtools-mcp-tests--rpc-sent' and
incoming dispatches into `emacs-devtools-mcp-tests--rpc-received'."
  (declare (indent 1) (debug (sexp body)))
  (let ((var (car binding))
        (rest (cdr binding)))
    `(let ((emacs-devtools-mcp-tests--rpc-sent nil)
           (emacs-devtools-mcp-tests--rpc-received nil)
           (proc nil)
           (,var nil))
       (unwind-protect
           (progn
             (setq proc (emacs-devtools-mcp-tests--rpc-make-process))
             (setq ,var
                   (make-instance
                    'emacs-devtools-mcp-rpc-connection
                    :name "edmcp-rpc-test"
                    :process proc
                    :request-dispatcher
                    (or ,(plist-get rest :request-fn)
                        (lambda (_c m p)
                          (push (list :kind 'request :method m :params p)
                                emacs-devtools-mcp-tests--rpc-received)
                          (list :ok t)))
                    :notification-dispatcher
                    (or ,(plist-get rest :notification-fn)
                        (lambda (_c m p)
                          (push (list :kind 'notification :method m :params p)
                                emacs-devtools-mcp-tests--rpc-received)))))
             (cl-letf*
                 ((orig-send (symbol-function 'process-send-string))
                  ((symbol-function 'process-send-string)
                   (lambda (p s)
                     (when (eq p proc)
                       (push s emacs-devtools-mcp-tests--rpc-sent))
                     ;; Don't forward to the real pipe process: we only
                     ;; want to observe what we *would* have sent.
                     (ignore orig-send))))
               ,@body))
         (when (process-live-p proc)
           (delete-process proc))))))

(defun emacs-devtools-mcp-tests--rpc-feed (conn bytes)
  "Inject BYTES into CONN's process filter as if read from the wire."
  (edmcp--rpc-process-filter (edmcp--rpc-process conn) bytes))

(defun emacs-devtools-mcp-tests--rpc-encode (plist)
  "Encode PLIST through `jsonrpc--json-encode' for fixture data."
  (jsonrpc--json-encode plist))

(ert-deftest emacs-devtools-mcp-tests/rpc-send-notification-frames-with-lf ()
  "`jsonrpc-notify' produces a single `<json>\\n' frame with no method munging."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (jsonrpc-notify c 'ping '(:foo 1))
    (should (= 1 (length emacs-devtools-mcp-tests--rpc-sent)))
    (let ((wire (car emacs-devtools-mcp-tests--rpc-sent)))
      (should (string-suffix-p "\n" wire))
      (should (= 1 (cl-count ?\n wire)))
      (let* ((json (substring wire 0 -1))
             (parsed (let ((json-object-type 'plist)
                           (json-array-type 'vector)
                           (json-false :json-false))
                       (json-parse-string json :object-type 'plist
                                          :null-object nil
                                          :false-object :json-false))))
        (should (equal "2.0" (plist-get parsed :jsonrpc)))
        (should (equal "ping" (plist-get parsed :method)))
        (should (equal '(:foo 1) (plist-get parsed :params)))))))

(ert-deftest emacs-devtools-mcp-tests/rpc-send-rejects-embedded-newline ()
  "Encoder refuses to emit a frame whose JSON contains a literal LF.
We monkey-patch `jsonrpc--json-encode' to inject a real LF and
verify the framing layer signals before any bytes are sent."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (cl-letf (((symbol-function 'jsonrpc--json-encode)
               (lambda (_obj) "{\"jsonrpc\":\"2.0\",\"method\":\"x\"\n}")))
      (should-error (jsonrpc-notify c 'x nil)
                    :type 'emacs-devtools-mcp-rpc-error))
    (should (null emacs-devtools-mcp-tests--rpc-sent))))

(ert-deftest emacs-devtools-mcp-tests/rpc-receive-notification ()
  "A complete notification frame is dispatched once, intact."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (let ((frame (concat
                  (emacs-devtools-mcp-tests--rpc-encode
                   '(:jsonrpc "2.0" :method "noted" :params (:n 42)))
                  "\n")))
      (emacs-devtools-mcp-tests--rpc-feed c frame))
    (should (= 1 (length emacs-devtools-mcp-tests--rpc-received)))
    (let ((m (car emacs-devtools-mcp-tests--rpc-received)))
      (should (eq 'notification (plist-get m :kind)))
      (should (eq 'noted (plist-get m :method)))
      (should (equal '(:n 42) (plist-get m :params))))))

(ert-deftest emacs-devtools-mcp-tests/rpc-receive-partial-then-complete ()
  "A frame split across two filter calls reaches the dispatcher exactly once."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (let* ((wire (concat
                  (emacs-devtools-mcp-tests--rpc-encode
                   '(:jsonrpc "2.0" :method "split" :params (:k "v")))
                  "\n"))
           (mid (/ (length wire) 2)))
      (emacs-devtools-mcp-tests--rpc-feed c (substring wire 0 mid))
      (should (null emacs-devtools-mcp-tests--rpc-received))
      (emacs-devtools-mcp-tests--rpc-feed c (substring wire mid)))
    (should (= 1 (length emacs-devtools-mcp-tests--rpc-received)))
    (should (eq 'split (plist-get (car emacs-devtools-mcp-tests--rpc-received)
                                  :method)))))

(ert-deftest emacs-devtools-mcp-tests/rpc-receive-two-frames-one-chunk ()
  "Two frames concatenated in one chunk dispatch as two messages, in order."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (let ((blob (concat
                 (emacs-devtools-mcp-tests--rpc-encode
                  '(:jsonrpc "2.0" :method "first" :params (:i 1)))
                 "\n"
                 (emacs-devtools-mcp-tests--rpc-encode
                  '(:jsonrpc "2.0" :method "second" :params (:i 2)))
                 "\n")))
      (emacs-devtools-mcp-tests--rpc-feed c blob))
    (should (= 2 (length emacs-devtools-mcp-tests--rpc-received)))
    (let ((received (nreverse emacs-devtools-mcp-tests--rpc-received)))
      (should (eq 'first (plist-get (nth 0 received) :method)))
      (should (eq 'second (plist-get (nth 1 received) :method))))))

(ert-deftest emacs-devtools-mcp-tests/rpc-receive-empty-lines-skipped ()
  "Empty lines (\\n\\n, leading \\n, trailing \\n) do not dispatch."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (emacs-devtools-mcp-tests--rpc-feed
     c (concat "\n\n"
               (emacs-devtools-mcp-tests--rpc-encode
                '(:jsonrpc "2.0" :method "only" :params nil))
               "\n\n\n"))
    (should (= 1 (length emacs-devtools-mcp-tests--rpc-received)))
    (should (eq 'only (plist-get (car emacs-devtools-mcp-tests--rpc-received)
                                 :method)))))

(ert-deftest emacs-devtools-mcp-tests/rpc-receive-large-frame ()
  "A 1 MiB JSON object is decoded equal to the encoded source."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (let* ((payload (make-string (* 1024 1024) ?a))
           (msg `(:jsonrpc "2.0" :method "big" :params (:s ,payload)))
           (wire (concat (emacs-devtools-mcp-tests--rpc-encode msg) "\n")))
      (should (> (length wire) (* 1024 1024)))
      (emacs-devtools-mcp-tests--rpc-feed c wire))
    (should (= 1 (length emacs-devtools-mcp-tests--rpc-received)))
    (let ((m (car emacs-devtools-mcp-tests--rpc-received)))
      (should (eq 'big (plist-get m :method)))
      (should (= (* 1024 1024)
                 (length (plist-get (plist-get m :params) :s)))))))

(ert-deftest emacs-devtools-mcp-tests/rpc-receive-malformed-line-skipped ()
  "An unparsable line is logged-and-dropped; subsequent frames still dispatch."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (cl-letf (((symbol-function 'jsonrpc--warn) #'ignore))
      (emacs-devtools-mcp-tests--rpc-feed
       c (concat "{not json\n"
                 (emacs-devtools-mcp-tests--rpc-encode
                  '(:jsonrpc "2.0" :method "after" :params nil))
                 "\n")))
    (should (= 1 (length emacs-devtools-mcp-tests--rpc-received)))
    (should (eq 'after (plist-get (car emacs-devtools-mcp-tests--rpc-received)
                                  :method)))))

(ert-deftest emacs-devtools-mcp-tests/rpc-property-random-chunking ()
  "Random envelopes split at random boundaries reconstruct losslessly.
Stand-in for a propcheck generative test (propcheck is not in the
nix-shell dependency set yet).  Twenty seeds, up to 10 messages,
chunks 1..32 bytes."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (let ((cl-random-state (cl-make-random-state 42)))
      (dotimes (trial 20)
        (setq emacs-devtools-mcp-tests--rpc-received nil)
        (let* ((n (1+ (cl-random 10 cl-random-state)))
               (msgs
                (cl-loop
                 for i below n
                 collect
                 (list :jsonrpc "2.0"
                       :method (format "m%d-%d" trial i)
                       :params
                       (list :i i
                             :s (make-string
                                 (cl-random 200 cl-random-state)
                                 ?x)))))
               (blob (mapconcat
                      (lambda (m)
                        (concat (emacs-devtools-mcp-tests--rpc-encode m)
                                "\n"))
                      msgs ""))
               (cursor 0))
          (while (< cursor (length blob))
            (let* ((chunk (1+ (cl-random 32 cl-random-state)))
                   (end (min (length blob) (+ cursor chunk))))
              (emacs-devtools-mcp-tests--rpc-feed
               c (substring blob cursor end))
              (setq cursor end)))
          (should (= n (length emacs-devtools-mcp-tests--rpc-received)))
          (let ((got (nreverse emacs-devtools-mcp-tests--rpc-received)))
            (cl-loop for sent in msgs
                     for received in got
                     do (should (string= (plist-get sent :method)
                                         (symbol-name
                                          (plist-get received :method))))
                     do (should (= (plist-get (plist-get sent :params) :i)
                                   (plist-get (plist-get received :params)
                                              :i))))))))))

(ert-deftest emacs-devtools-mcp-tests/rpc-running-and-shutdown ()
  "`jsonrpc-running-p' tracks process liveness; shutdown deletes it."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-rpc (c)
    (should (jsonrpc-running-p c))
    (jsonrpc-shutdown c)
    (should-not (jsonrpc-running-p c))))

(ert-deftest emacs-devtools-mcp-tests/rpc-real-cat-round-trip ()
  "End-to-end framing: bytes through `cat' come back and dispatch.
Skipped when `cat' is not on PATH (should never happen in
nix-shell, but the safety net is cheap)."
  :tags '(:fast)
  (skip-unless (executable-find "cat"))
  (let* ((received nil)
         (proc (make-process :name "edmcp-cat-loop"
                             :command '("cat")
                             :coding 'utf-8-unix
                             :connection-type 'pipe
                             :noquery t))
         (conn (make-instance
                'emacs-devtools-mcp-rpc-connection
                :name "edmcp-cat-loop"
                :process proc
                :notification-dispatcher
                (lambda (_c m p) (push (cons m p) received)))))
    (unwind-protect
        (progn
          (jsonrpc-notify conn 'echo '(:n 7))
          (jsonrpc-notify conn 'echo2 '(:s "hello"))
          (with-timeout (2 (error "cat round-trip timed out"))
            (while (< (length received) 2)
              (accept-process-output proc 0.05)))
          (let ((got (nreverse received)))
            (should (eq 'echo (car (nth 0 got))))
            (should (equal '(:n 7) (cdr (nth 0 got))))
            (should (eq 'echo2 (car (nth 1 got))))
            (should (equal '(:s "hello") (cdr (nth 1 got))))))
      (jsonrpc-shutdown conn t))))

;;;; ___Server___
;;
;; Unix-socket server lifecycle.  Each test cooks its own
;; XDG_RUNTIME_DIR under a temp directory and tears down the server +
;; the directory on exit.

(defmacro emacs-devtools-mcp-tests--with-server-env (&rest body)
  "Run BODY with a fresh tmpdir installed as XDG_RUNTIME_DIR."
  (declare (indent 0) (debug (body)))
  `(let* ((tmpdir (make-temp-file "edmcp-test-xdg-" t))
          (process-environment
           (cons (concat "XDG_RUNTIME_DIR=" tmpdir)
                 (cl-remove-if
                  (lambda (entry) (string-prefix-p "XDG_RUNTIME_DIR=" entry))
                  process-environment))))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (emacs-devtools-mcp-server-stop))
       (delete-directory tmpdir t))))

(ert-deftest emacs-devtools-mcp-tests/server-hard-fails-without-xdg ()
  "Server refuses to start when XDG_RUNTIME_DIR is unset."
  :tags '(:fast)
  (let ((process-environment
         (cl-remove-if (lambda (e) (string-prefix-p "XDG_RUNTIME_DIR=" e))
                       process-environment)))
    (should-error (emacs-devtools-mcp-server-start) :type 'user-error)))

(ert-deftest emacs-devtools-mcp-tests/server-creates-dir-and-socket ()
  "First start creates the socket dir 0700 and the socket 0600."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (let* ((dir (edmcp--server-socket-dir))
           (path (edmcp--server-socket-path))
           (dir-modes (file-modes dir))
           (sock-modes (file-modes path))
           (sock-attrs (file-attributes path)))
      (should (file-directory-p dir))
      (should (= #o700 (logand dir-modes #o777)))
      (should (file-exists-p path))
      (should (= #o600 (logand sock-modes #o777)))
      (should (eq ?s (aref (file-attribute-modes sock-attrs) 0))))))

(ert-deftest emacs-devtools-mcp-tests/server-start-twice-is-noop ()
  "Calling start twice returns the same process; no rebind."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (let* ((p1 (emacs-devtools-mcp-server-start))
           (p2 (emacs-devtools-mcp-server-start)))
      (should (eq p1 p2))
      (should (process-live-p p1)))))

(ert-deftest emacs-devtools-mcp-tests/server-stop-is-idempotent ()
  "Stop twice does not error, even when never started."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (should-not (emacs-devtools-mcp-server-stop))
    (emacs-devtools-mcp-server-start)
    (let ((path emacs-devtools-mcp-server--socket-path))
      (emacs-devtools-mcp-server-stop)
      (should-not (file-exists-p path))
      (should-not (emacs-devtools-mcp-server-stop)))))

(ert-deftest emacs-devtools-mcp-tests/server-refuses-regular-file ()
  "Pre-existing regular file at the socket path → user-error, no bind."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (edmcp--server-ensure-dir)
    (let ((path (edmcp--server-socket-path)))
      (with-temp-file path (insert "not a socket"))
      (should-error (emacs-devtools-mcp-server-start) :type 'user-error)
      (should (file-exists-p path))
      (should-not emacs-devtools-mcp-server--process))))

(ert-deftest emacs-devtools-mcp-tests/server-refuses-symlink ()
  "Pre-existing symlink at the socket path → user-error, no bind."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (edmcp--server-ensure-dir)
    (let* ((path (edmcp--server-socket-path))
           (target (expand-file-name "innocent" temporary-file-directory)))
      (with-temp-file target (insert "anything"))
      (unwind-protect
          (progn
            (make-symbolic-link target path)
            (should-error (emacs-devtools-mcp-server-start) :type 'user-error)
            (should (file-symlink-p path)))
        (ignore-errors (delete-file target))))))

(ert-deftest emacs-devtools-mcp-tests/server-unlinks-stale-socket ()
  "A stale socket from a prior bind is unlinked and rebound cleanly."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (edmcp--server-ensure-dir)
    (let* ((path (edmcp--server-socket-path))
           (stale (make-network-process
                   :name "edmcp-stale"
                   :family 'local
                   :server t
                   :service path
                   :noquery t)))
      (delete-process stale)
      (should (file-exists-p path))
      (should (eq ?s (aref (file-attribute-modes (file-attributes path)) 0)))
      (let ((proc (emacs-devtools-mcp-server-start)))
        (should (process-live-p proc))
        (should (file-exists-p path))))))

(ert-deftest emacs-devtools-mcp-tests/server-registers-kill-emacs-hook ()
  "Starting the server adds a `kill-emacs-hook' entry; stop removes it."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (should (memq 'emacs-devtools-mcp-server-stop kill-emacs-hook))
    (emacs-devtools-mcp-server-stop)
    (should-not (memq 'emacs-devtools-mcp-server-stop kill-emacs-hook))))

(ert-deftest emacs-devtools-mcp-tests/server-accept-instantiates-rpc-connection ()
  "A real client connecting through the bound socket is dispatched as RPC.
Uses Emacs as its own client (no subprocess) so the test stays
:fast.  Verifies the server's :log hook wraps the accepted child
in an `emacs-devtools-mcp-rpc-connection'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (let* ((path emacs-devtools-mcp-server--socket-path)
           (received nil)
           (client (make-network-process
                    :name "edmcp-test-client"
                    :family 'local
                    :service path
                    :coding 'utf-8-unix
                    :noquery t
                    :filter (lambda (_p s) (push s received)))))
      (unwind-protect
          (progn
            ;; Drain the accept callback.
            (with-timeout (2 (error "accept never fired"))
              (while (null emacs-devtools-mcp-server--connections)
                (accept-process-output nil 0.05)))
            (should (= 1 (length emacs-devtools-mcp-server--connections)))
            (let ((conn (car emacs-devtools-mcp-server--connections)))
              (should (object-of-class-p
                       conn 'emacs-devtools-mcp-rpc-connection))
              (jsonrpc-notify conn 'hello '(:k "v")))
            (with-timeout (2 (error "no echo from server"))
              (while (null received)
                (accept-process-output client 0.05)))
            (let ((wire (apply #'concat (nreverse received))))
              (should (string-suffix-p "\n" wire))
              (should (string-match-p "\"method\":\"hello\"" wire))))
        (when (process-live-p client) (delete-process client))))))

;;;; ___Auth___
;;
;; Per-launch token + first-frame initialize gate.

(defun emacs-devtools-mcp-tests--connect-client ()
  "Open a real client process to the running server.
Caller must `delete-process' the result."
  (make-network-process
   :name "edmcp-test-client"
   :family 'local
   :service emacs-devtools-mcp-server--socket-path
   :coding 'utf-8-unix
   :noquery t))

(defun emacs-devtools-mcp-tests--client-send (client obj)
  "Encode OBJ as one MCP frame and write it to CLIENT."
  (process-send-string client
                       (concat (jsonrpc--json-encode obj) "\n")))

(defun emacs-devtools-mcp-tests--client-await-frame (client buf)
  "Wait until BUF (a marker pointing into client output) contains a `\\n'.
Returns the parsed JSON object or signals on timeout.  BUF is a
plain mutable list (1-element) holding the accumulated string;
the client filter pushes here.  CLIENT is the process to drive
via `accept-process-output'."
  (with-timeout (3 (error "client never received a frame: %S" (car buf)))
    (while (not (string-match-p "\n" (or (car buf) "")))
      (accept-process-output client 0.05)))
  (let* ((wire (car buf))
         (nl (string-search "\n" wire))
         (line (substring wire 0 nl))
         (rest (substring wire (1+ nl))))
    (setcar buf rest)
    (with-temp-buffer
      (insert line)
      (goto-char (point-min))
      (jsonrpc--json-read))))

(defmacro emacs-devtools-mcp-tests--with-client (binding &rest body)
  "Bind BINDING (CLIENT BUF) to a connected client + filter buffer.
BUF is a 1-element list mutated by the client filter."
  (declare (indent 1) (debug ((symbolp symbolp) body)))
  (pcase-let ((`(,client ,buf) binding))
    `(let* ((,buf (list ""))
            (,client (emacs-devtools-mcp-tests--connect-client)))
       (set-process-filter
        ,client
        (lambda (_p s)
          (setcar ,buf (concat (car ,buf) s))))
       (unwind-protect
           (progn ,@body)
         (when (process-live-p ,client) (delete-process ,client))))))

(ert-deftest emacs-devtools-mcp-tests/auth-token-file-is-0600 ()
  "Server-start writes the token file at the expected path with mode 0600."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (let* ((path (edmcp--auth-token-file
                  emacs-devtools-mcp-server--socket-path))
           (modes (file-modes path)))
      (should (file-exists-p path))
      (should (= #o600 (logand modes #o777)))
      (should (stringp emacs-devtools-mcp-auth--token))
      (should (= 64 (length emacs-devtools-mcp-auth--token))))))

(ert-deftest emacs-devtools-mcp-tests/auth-stop-removes-token-file ()
  "Server-stop clears the in-memory token and unlinks the file."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (let ((path (edmcp--auth-token-file
                 emacs-devtools-mcp-server--socket-path)))
      (emacs-devtools-mcp-server-stop)
      (should-not emacs-devtools-mcp-auth--token)
      (should-not (file-exists-p path)))))

(ert-deftest emacs-devtools-mcp-tests/auth-restart-rotates-token ()
  "A second `server-start' produces a different token from the first."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (let ((t1 emacs-devtools-mcp-auth--token))
      (emacs-devtools-mcp-server-stop)
      (emacs-devtools-mcp-server-start)
      (should-not (equal t1 emacs-devtools-mcp-auth--token)))))

(ert-deftest emacs-devtools-mcp-tests/auth-initialize-with-right-token-succeeds ()
  "An `initialize' carrying the current token gets a result reply."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (emacs-devtools-mcp-tests--with-client (client buf)
      (let ((token emacs-devtools-mcp-auth--token))
        (emacs-devtools-mcp-tests--client-send
         client `(:jsonrpc "2.0"
                  :id 1
                  :method "initialize"
                  :params (:_meta (:token ,token))))
        (let ((reply (emacs-devtools-mcp-tests--client-await-frame
                      client buf)))
          (should (equal "2.0" (plist-get reply :jsonrpc)))
          (should (equal 1 (plist-get reply :id)))
          (should (plist-get reply :result))
          (should-not (plist-get reply :error))
          (should (equal "emacs-devtools-mcp"
                         (plist-get
                          (plist-get (plist-get reply :result) :serverInfo)
                          :name))))))))

(ert-deftest emacs-devtools-mcp-tests/auth-initialize-with-wrong-token-rejects ()
  "An `initialize' carrying a wrong token returns -32600 and closes."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (emacs-devtools-mcp-tests--with-client (client buf)
      (emacs-devtools-mcp-tests--client-send
       client '(:jsonrpc "2.0"
                :id 1
                :method "initialize"
                :params (:_meta (:token "deadbeef"))))
      (let ((reply (emacs-devtools-mcp-tests--client-await-frame
                    client buf)))
        (should (equal 1 (plist-get reply :id)))
        (let ((err (plist-get reply :error)))
          (should err)
          (should (eq -32600 (plist-get err :code)))))
      (with-timeout (3 (error "server did not close client"))
        (while (process-live-p client)
          (accept-process-output client 0.05))))))

(ert-deftest emacs-devtools-mcp-tests/auth-non-initialize-first-frame-closes ()
  "A non-initialize first request returns -32600 and the connection closes."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (emacs-devtools-mcp-tests--with-client (client buf)
      (emacs-devtools-mcp-tests--client-send
       client '(:jsonrpc "2.0" :id 1 :method "tools/list"))
      (let ((reply (emacs-devtools-mcp-tests--client-await-frame
                    client buf)))
        (should (eq -32600 (plist-get (plist-get reply :error) :code))))
      (with-timeout (3 (error "server did not close client"))
        (while (process-live-p client)
          (accept-process-output client 0.05))))))

(ert-deftest emacs-devtools-mcp-tests/auth-initialize-without-meta-token-rejects ()
  "An `initialize' without `_meta.token' fails the same way as a wrong token."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (emacs-devtools-mcp-tests--with-client (client buf)
      (emacs-devtools-mcp-tests--client-send
       client '(:jsonrpc "2.0" :id 1 :method "initialize" :params (:x 1)))
      (let ((reply (emacs-devtools-mcp-tests--client-await-frame
                    client buf)))
        (should (eq -32600 (plist-get (plist-get reply :error) :code)))))))

(ert-deftest emacs-devtools-mcp-tests/auth-check-token-constant-time-shape ()
  "`auth--check-token' rejects nil, wrong-length, and wrong-content; accepts equal."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-auth--token "abcd1234"))
    (should-not (emacs-devtools-mcp-auth--check-token nil))
    (should-not (emacs-devtools-mcp-auth--check-token "abcd"))
    (should-not (emacs-devtools-mcp-auth--check-token "abcd1235"))
    (should     (emacs-devtools-mcp-auth--check-token "abcd1234"))))

;;;; ___Registry___
;;
;; `emacs-devtools-mcp-deftool' macro + JSON-Schema-subset validator.
;; The registry is dynamic (defvar), so each test let-binds a fresh
;; hash table to keep registrations isolated.

(defmacro emacs-devtools-mcp-tests--with-fresh-registry (&rest body)
  "Run BODY with a freshly-emptied tool registry."
  (declare (indent 0) (debug (body)))
  `(let ((emacs-devtools-mcp--tool-registry (make-hash-table :test 'equal)))
     ,@body))

;;;;; ___Validator (positive cases)___

(ert-deftest emacs-devtools-mcp-tests/validate-string-ok ()
  "A string instance passes a `:type \"string\"' schema."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp--validate '(:type "string") "abc")))

(ert-deftest emacs-devtools-mcp-tests/validate-integer-ok ()
  "An integer passes `:type \"integer\"'."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp--validate '(:type "integer") 42)))

(ert-deftest emacs-devtools-mcp-tests/validate-number-accepts-integer-and-float ()
  "Both integer and float satisfy `:type \"number\"'."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp--validate '(:type "number") 42))
  (should-not (emacs-devtools-mcp--validate '(:type "number") 3.14)))

(ert-deftest emacs-devtools-mcp-tests/validate-boolean-ok ()
  "Both wire booleans (t and :json-false) satisfy `:type \"boolean\"'."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp--validate '(:type "boolean") t))
  (should-not (emacs-devtools-mcp--validate '(:type "boolean") :json-false)))

(ert-deftest emacs-devtools-mcp-tests/validate-null-ok ()
  "Nil satisfies `:type \"null\"'."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp--validate '(:type "null") nil)))

(ert-deftest emacs-devtools-mcp-tests/validate-array-ok ()
  "A vector satisfies `:type \"array\"'."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp--validate '(:type "array") [1 2 3]))
  (should-not (emacs-devtools-mcp--validate '(:type "array") [])))

(ert-deftest emacs-devtools-mcp-tests/validate-object-ok ()
  "Plists with keyword keys -- and nil for empty -- satisfy `:type \"object\"'."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp--validate '(:type "object") '(:a 1 :b "x")))
  (should-not (emacs-devtools-mcp--validate '(:type "object") nil)))

(ert-deftest emacs-devtools-mcp-tests/validate-multi-type-ok ()
  "A `:type' list admits any of its members."
  :tags '(:fast)
  (let ((schema '(:type ("string" "null"))))
    (should-not (emacs-devtools-mcp--validate schema "x"))
    (should-not (emacs-devtools-mcp--validate schema nil))))

(ert-deftest emacs-devtools-mcp-tests/validate-required-and-properties-ok ()
  "Required + properties: all required present and well-typed passes."
  :tags '(:fast)
  (let ((schema '(:type "object"
                  :properties ((form . (:type "string"))
                               (n    . (:type "integer")))
                  :required ("form"))))
    (should-not (emacs-devtools-mcp--validate
                 schema '(:form "x" :n 7)))
    (should-not (emacs-devtools-mcp--validate
                 schema '(:form "x")))))

(ert-deftest emacs-devtools-mcp-tests/validate-const-ok ()
  "An exactly-equal value satisfies `:const'."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp--validate '(:const "x") "x"))
  (should-not (emacs-devtools-mcp--validate '(:const t) t)))

(ert-deftest emacs-devtools-mcp-tests/validate-enum-ok ()
  "Membership in `:enum' passes."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp--validate '(:enum (1 2 3)) 2)))

(ert-deftest emacs-devtools-mcp-tests/validate-oneof-ok-single-match ()
  "`:oneOf' with exactly one matching alternative passes (host/spawn shape).
Each alternative must `:required' its discriminator -- otherwise an
empty object would match both because neither key would be checked."
  :tags '(:fast)
  (let ((schema '(:oneOf
                  ((:type "object"
                    :properties ((host . (:const t)))
                    :required ("host"))
                   (:type "object"
                    :properties ((spawn . (:type "string")))
                    :required ("spawn"))))))
    (should-not (emacs-devtools-mcp--validate schema '(:host t)))
    (should-not (emacs-devtools-mcp--validate schema '(:spawn "h0")))))

;;;;; ___Validator (negative cases)___

(defun emacs-devtools-mcp-tests--validate (schema instance)
  "Helper: return the failure (REASON . PATH) from validating INSTANCE under SCHEMA."
  (emacs-devtools-mcp--validate schema instance))

(ert-deftest emacs-devtools-mcp-tests/validate-string-rejects-integer ()
  "An integer for a string slot fails with a type-mismatch reason."
  :tags '(:fast)
  (let ((fail (emacs-devtools-mcp-tests--validate '(:type "string") 42)))
    (should fail)
    (should (string-match-p "expected type" (car fail)))))

(ert-deftest emacs-devtools-mcp-tests/validate-integer-rejects-string ()
  "A string for an integer slot fails."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:type "integer") "x")))

(ert-deftest emacs-devtools-mcp-tests/validate-integer-rejects-float ()
  "A float for an integer slot fails (integer is strict, number is lenient)."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:type "integer") 3.14)))

(ert-deftest emacs-devtools-mcp-tests/validate-boolean-rejects-string ()
  "A string for a boolean slot fails."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:type "boolean") "x")))

(ert-deftest emacs-devtools-mcp-tests/validate-null-rejects-string ()
  "A string for a null slot fails."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:type "null") "x")))

(ert-deftest emacs-devtools-mcp-tests/validate-array-rejects-string ()
  "A string for an array slot fails."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:type "array") "x")))

(ert-deftest emacs-devtools-mcp-tests/validate-array-rejects-list ()
  "A list (not a vector) for an array slot fails -- arrays go on the wire as vectors."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:type "array") '(1 2 3))))

(ert-deftest emacs-devtools-mcp-tests/validate-object-rejects-vector ()
  "A vector for an object slot fails."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:type "object") [1 2])))

(ert-deftest emacs-devtools-mcp-tests/validate-object-rejects-non-keyword-keys ()
  "A non-keyword-keyed plist-shaped list fails the object check."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:type "object") '("a" 1))))

(ert-deftest emacs-devtools-mcp-tests/validate-object-rejects-odd-length ()
  "An odd-length list fails the object check."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:type "object") '(:a 1 :b))))

(ert-deftest emacs-devtools-mcp-tests/validate-const-rejects-mismatch ()
  "A non-equal value fails `:const' with a `const' reason."
  :tags '(:fast)
  (let ((fail (emacs-devtools-mcp-tests--validate '(:const "x") "y")))
    (should fail)
    (should (string-match-p "const" (car fail)))))

(ert-deftest emacs-devtools-mcp-tests/validate-const-boolean-mismatch ()
  "Booleans must match the const exactly: t ≠ :json-false."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate '(:const t) :json-false)))

(ert-deftest emacs-devtools-mcp-tests/validate-enum-rejects-non-member ()
  "A value outside `:enum' fails with an enum reason."
  :tags '(:fast)
  (let ((fail (emacs-devtools-mcp-tests--validate '(:enum (1 2 3)) 5)))
    (should fail)
    (should (string-match-p "enum" (car fail)))))

(ert-deftest emacs-devtools-mcp-tests/validate-required-missing ()
  "A missing required property fails with the property name in the path."
  :tags '(:fast)
  (let* ((schema '(:type "object"
                   :properties ((form . (:type "string")))
                   :required ("form")))
         (fail (emacs-devtools-mcp-tests--validate schema '())))
    (should fail)
    (should (string-match-p "missing required" (car fail)))
    (should (member "form" (cdr fail)))))

(ert-deftest emacs-devtools-mcp-tests/validate-nested-required-missing ()
  "A missing required property of a nested object reports the full path."
  :tags '(:fast)
  (let* ((schema '(:type "object"
                   :properties
                   ((target . (:type "object"
                               :properties ((spawn . (:type "string")))
                               :required ("spawn")))) ))
         (fail (emacs-devtools-mcp-tests--validate
                schema '(:target (:other 1)))))
    (should fail)
    (should (equal '("target" "spawn") (cdr fail)))))

(ert-deftest emacs-devtools-mcp-tests/validate-nested-wrong-type-with-path ()
  "A wrong-typed nested property reports the property name in the path."
  :tags '(:fast)
  (let* ((schema '(:type "object"
                   :properties ((form . (:type "string")))))
         (fail (emacs-devtools-mcp-tests--validate schema '(:form 42))))
    (should fail)
    (should (member "form" (cdr fail)))))

(ert-deftest emacs-devtools-mcp-tests/validate-multi-type-rejects-other ()
  "A multi-`:type' schema rejects an instance of none of its types."
  :tags '(:fast)
  (should (emacs-devtools-mcp-tests--validate
           '(:type ("string" "null")) 42)))

(ert-deftest emacs-devtools-mcp-tests/validate-oneof-zero-matches ()
  "`:oneOf' with no matching alternative fails."
  :tags '(:fast)
  (let* ((schema '(:oneOf
                   ((:type "object" :properties ((host . (:const t))))
                    (:type "object" :properties ((spawn . (:type "string")))))))
         (fail (emacs-devtools-mcp-tests--validate schema "host")))
    (should fail)
    (should (string-match-p "no oneOf" (car fail)))))

(ert-deftest emacs-devtools-mcp-tests/validate-oneof-multiple-matches ()
  "`:oneOf' with two matching alternatives fails (ambiguous)."
  :tags '(:fast)
  (let* ((schema '(:oneOf ((:type "object") (:type ("object" "null")))))
         (fail (emacs-devtools-mcp-tests--validate schema '(:a 1))))
    (should fail)
    (should (string-match-p "multiple" (car fail)))))

(ert-deftest emacs-devtools-mcp-tests/validate-required-partial ()
  "Partial required satisfies, fully-missing required fails."
  :tags '(:fast)
  (let ((schema '(:type "object"
                  :properties ((a . (:type "integer"))
                               (b . (:type "integer")))
                  :required ("a" "b"))))
    (should-not (emacs-devtools-mcp--validate schema '(:a 1 :b 2)))
    (let ((fail (emacs-devtools-mcp--validate schema '(:a 1))))
      (should fail)
      (should (member "b" (cdr fail))))))

;;;;; ___deftool registration___

(ert-deftest emacs-devtools-mcp-tests/deftool-registers-record ()
  "`deftool' inserts the record at the snake_case name with all fields."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(emacs-devtools-mcp-deftool ping-tool
          "Reply with pong."
        :cost :fast
        :read-only t
        :idempotent t
        :schema '(:type "object")
        :handler (lambda (_p) "pong"))
     t)
    (let ((rec (gethash "ping_tool" emacs-devtools-mcp--tool-registry)))
      (should rec)
      (should (equal "ping_tool"      (plist-get rec :name)))
      (should (equal "Reply with pong." (plist-get rec :doc)))
      (should (eq :fast               (plist-get rec :cost)))
      (should (eq t                   (plist-get rec :read-only)))
      (should (eq t                   (plist-get rec :idempotent)))
      (should (equal '(:type "object") (plist-get rec :schema)))
      (should (functionp              (plist-get rec :handler))))))

(ert-deftest emacs-devtools-mcp-tests/deftool-snake-case-mapping ()
  "Kebab-cased Lisp names become snake_case wire names."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(emacs-devtools-mcp-deftool screenshot-frame-tree
          "..."
        :handler (lambda (_p) nil))
     t)
    (should (gethash "screenshot_frame_tree"
                     emacs-devtools-mcp--tool-registry))))

(ert-deftest emacs-devtools-mcp-tests/deftool-duplicate-name-signals ()
  "Re-registering a name signals; the existing record is preserved."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(emacs-devtools-mcp-deftool dup-name
          "First."
        :handler (lambda (_p) "first"))
     t)
    (should-error
     (eval
      '(emacs-devtools-mcp-deftool dup-name
           "Second."
         :handler (lambda (_p) "second"))
      t))
    (let ((rec (gethash "dup_name" emacs-devtools-mcp--tool-registry)))
      (should (equal "First." (plist-get rec :doc))))))

(ert-deftest emacs-devtools-mcp-tests/deftool-missing-handler-signals ()
  "A `deftool' with no `:handler' fails at macroexpand time."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (should-error
     (macroexpand
      '(emacs-devtools-mcp-deftool no-handler
           "Bad."
         :cost :fast)))))

(ert-deftest emacs-devtools-mcp-tests/deftool-bad-cost-signals ()
  "A `deftool' with an invalid `:cost' fails at macroexpand time."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (should-error
     (macroexpand
      '(emacs-devtools-mcp-deftool bad-cost
           "Bad."
         :cost :ridiculous
         :handler (lambda (_p) nil))))))

(ert-deftest emacs-devtools-mcp-tests/deftool-fast-not-wrapped ()
  "A `:fast' handler runs even when the slow timeout is unreachably small.
This proves the macro does not wrap `:fast' tools in `with-timeout'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (let ((emacs-devtools-mcp-slow-tool-timeout 0))
      (eval
       '(emacs-devtools-mcp-deftool fast-tool
            "Fast."
          :cost :fast
          :handler (lambda (_p) (sleep-for 0.01) :ok))
       t)
      (let* ((rec (gethash "fast_tool" emacs-devtools-mcp--tool-registry))
             (handler (plist-get rec :handler)))
        (should (eq :ok (funcall handler nil)))))))

(ert-deftest emacs-devtools-mcp-tests/deftool-slow-times-out ()
  "A `:slow' handler that exceeds the timeout signals `jsonrpc-error'.
The wrapped handler must surface a structured error rather than
return its slow value."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (let ((emacs-devtools-mcp-slow-tool-timeout 0.05))
      (eval
       '(emacs-devtools-mcp-deftool slow-tool
            "Slow."
          :cost :slow
          :handler (lambda (_p) (sleep-for 1) :unreachable))
       t)
      (let* ((rec (gethash "slow_tool" emacs-devtools-mcp--tool-registry))
             (handler (plist-get rec :handler)))
        (should-error (funcall handler nil) :type 'jsonrpc-error)))))

(ert-deftest emacs-devtools-mcp-tests/deftool-slow-runs-when-fast ()
  "A `:slow' handler that returns under the deadline returns its value."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (let ((emacs-devtools-mcp-slow-tool-timeout 5))
      (eval
       '(emacs-devtools-mcp-deftool slow-but-quick
            "Slow but quick."
          :cost :slow
          :handler (lambda (params) (list :got params)))
       t)
      (let* ((rec (gethash "slow_but_quick" emacs-devtools-mcp--tool-registry))
             (handler (plist-get rec :handler)))
        (should (equal '(:got (:n 1)) (funcall handler '(:n 1))))))))

(ert-deftest emacs-devtools-mcp-tests/deftool-tool-record-helper ()
  "`emacs-devtools-mcp--tool-record' returns the registered record."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(emacs-devtools-mcp-deftool helper-test
          "Doc."
        :handler (lambda (_p) nil))
     t)
    (should (emacs-devtools-mcp--tool-record "helper_test"))
    (should-not (emacs-devtools-mcp--tool-record "no_such_tool"))))

(ert-deftest emacs-devtools-mcp-tests/array-fields-encode-as-json-arrays ()
  "Every documented array field round-trips as a JSON array, not an object.
`json-serialize' encodes vectors as JSON arrays and Elisp lists as
JSON objects -- so a list-of-strings handler return would give the
client `\\='alist-shaped\\=' garbage instead of the expected `\\=[\"a\"]\\='.
The describe-hooks shape regression (commit `d08804d') hit exactly
this trap.  This test calls every easy-to-call array-returning
handler and asserts the documented array slot is a vector both
in-memory and after a `json-serialize'/`json-parse-string'
round-trip with `:array-type \\='array'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (with-temp-buffer
      (rename-buffer "edmcp-shape-fixture" t)
      (dolist (case `((,#'edmcp--tools-list-buffers () :buffers)
                      (,#'edmcp--tools-list-faces () :faces)
                      (,#'edmcp--tools-list-warnings () :warnings)
                      (,#'edmcp--tools-list-messages () :messages)
                      (,#'edmcp--tools-describe-keymap
                       (:keymap "global-map") :bindings)
                      (,#'edmcp--tools-describe-hooks () :hooks)
                      (,#'edmcp--tools-describe-hooks
                       (:hook "kill-emacs-hook") :functions)
                      (,#'edmcp--tools-spawn-list () :handles)
                      (,#'edmcp--tools-where-is
                       (:command "self-insert-command") :bindings)))
        (let* ((handler (nth 0 case))
               (params  (nth 1 case))
               (field   (nth 2 case))
               (res     (funcall handler params))
               (val     (plist-get res field)))
          (should (vectorp val))
          ;; Wire-shape sanity: an empty vector encodes as JSON `[]'
          ;; (a list of zero strings would encode as `{}').  Pin the
          ;; contract on a payload-free copy of the same shape so the
          ;; test does not depend on the buffer/face contents being
          ;; valid UTF-8 (some bindings carry raw bytes that
          ;; `json-serialize' rejects, which is a separate concern).
          (let* ((json (json-serialize (list field (vector))))
                 (parsed (json-parse-string
                          json :object-type 'plist
                          :array-type 'array)))
            (should (vectorp (plist-get parsed field)))
            (should (= 0 (length (plist-get parsed field))))))))))

;;;; ___Relay___
;;
;; `bin/emacs-devtools-mcp' POSIX-sh stdio<->socket relay.  Tests
;; spawn the relay as a subprocess, drive it via stdin/stdout, and
;; talk to a host server bound inside the test Emacs.  jq + socat are
;; provided by `shell.nix'; tests skip when missing.

(defconst emacs-devtools-mcp-tests--relay-path
  (expand-file-name
   "../bin/emacs-devtools-mcp"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Absolute path to the `bin/emacs-devtools-mcp' relay script.")

(defun emacs-devtools-mcp-tests--relay-start (env stdout-fn stderr-buf)
  "Spawn the relay as a child process under environment ENV.
STDOUT-FN is the process filter; STDERR-BUF is a buffer that will
collect the relay's stderr.  Returns the live process."
  (let ((process-environment (append env process-environment)))
    (make-process
     :name "edmcp-relay"
     :command (list emacs-devtools-mcp-tests--relay-path)
     :coding 'utf-8-unix
     :connection-type 'pipe
     :noquery t
     :filter (lambda (_p s) (funcall stdout-fn s))
     :stderr stderr-buf)))

(defun emacs-devtools-mcp-tests--relay-drain-stderr (stderr-buf)
  "Wait for the relay's stderr pipe sub-process attached to STDERR-BUF.
With `:stderr BUFFER', `make-process' creates a hidden pipe process
that asynchronously pumps the child's stderr into STDERR-BUF; the
main process can exit before that pipe drains.  Block until the
pipe sub-process is gone (or a 1 s budget runs out)."
  (let ((deadline (+ (float-time) 1.0)))
    (while (and (< (float-time) deadline)
                (cl-some (lambda (p)
                           (and (eq (process-buffer p) stderr-buf)
                                (process-live-p p)))
                         (process-list)))
      (accept-process-output nil 0.05))))

(ert-deftest emacs-devtools-mcp-tests/relay-hard-fails-without-xdg ()
  "Relay exits non-zero with a message when XDG_RUNTIME_DIR is unset."
  :tags '(:fast)
  (skip-unless (file-executable-p emacs-devtools-mcp-tests--relay-path))
  (let* ((stderr (generate-new-buffer " *edmcp-relay-stderr*"))
         (proc (emacs-devtools-mcp-tests--relay-start
                '("XDG_RUNTIME_DIR=") (lambda (_) nil) stderr)))
    (unwind-protect
        (progn
          (with-timeout (3 (error "relay did not exit"))
            (while (process-live-p proc)
              (accept-process-output proc 0.05)))
          (emacs-devtools-mcp-tests--relay-drain-stderr stderr)
          (should (not (zerop (process-exit-status proc))))
          (with-current-buffer stderr
            (should (string-match-p "XDG_RUNTIME_DIR is unset"
                                    (buffer-string)))))
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer stderr))))

(ert-deftest emacs-devtools-mcp-tests/relay-hard-fails-without-socket ()
  "Relay exits non-zero when the socket path does not exist."
  :tags '(:fast)
  (skip-unless (file-executable-p emacs-devtools-mcp-tests--relay-path))
  (let* ((tmpdir (make-temp-file "edmcp-relay-test-" t))
         (stderr (generate-new-buffer " *edmcp-relay-stderr*"))
         (proc (emacs-devtools-mcp-tests--relay-start
                (list (concat "XDG_RUNTIME_DIR=" tmpdir))
                (lambda (_) nil) stderr)))
    (unwind-protect
        (progn
          (with-timeout (3 (error "relay did not exit"))
            (while (process-live-p proc)
              (accept-process-output proc 0.05)))
          (emacs-devtools-mcp-tests--relay-drain-stderr stderr)
          (should (not (zerop (process-exit-status proc))))
          (with-current-buffer stderr
            (should (string-match-p "no socket at" (buffer-string)))))
      (when (process-live-p proc) (delete-process proc))
      (delete-directory tmpdir t)
      (kill-buffer stderr))))

(ert-deftest emacs-devtools-mcp-tests/relay-hard-fails-without-token ()
  "Relay exits non-zero when the token file is missing.
We pre-place a real socket via `make-network-process' so the
socket-existence check passes and the token check is exercised."
  :tags '(:fast)
  (skip-unless (file-executable-p emacs-devtools-mcp-tests--relay-path))
  (let* ((tmpdir (make-temp-file "edmcp-relay-test-" t))
         (sockdir (expand-file-name "edmcp" tmpdir))
         (sockpath (expand-file-name "default.sock" sockdir))
         (stderr (generate-new-buffer " *edmcp-relay-stderr*"))
         server proc)
    (unwind-protect
        (progn
          (make-directory sockdir t)
          (set-file-modes sockdir #o700)
          (setq server (make-network-process
                        :name "edmcp-relay-test-srv"
                        :family 'local
                        :server t
                        :service sockpath
                        :noquery t))
          (setq proc (emacs-devtools-mcp-tests--relay-start
                      (list (concat "XDG_RUNTIME_DIR=" tmpdir))
                      (lambda (_) nil) stderr))
          (with-timeout (3 (error "relay did not exit"))
            (while (process-live-p proc)
              (accept-process-output proc 0.05)))
          (emacs-devtools-mcp-tests--relay-drain-stderr stderr)
          (should (not (zerop (process-exit-status proc))))
          (with-current-buffer stderr
            (should (string-match-p "no readable token file"
                                    (buffer-string)))))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when (and server (process-live-p server)) (delete-process server))
      (when (file-exists-p sockpath) (ignore-errors (delete-file sockpath)))
      (delete-directory tmpdir t)
      (kill-buffer stderr))))

;;;; ___Dispatch___
;;
;; tools/list, tools/call, ping, and the protocol-level error envelope.

(ert-deftest emacs-devtools-mcp-tests/dispatch-tools-list-shape ()
  "`tools/list' returns a vector of entries sorted by name with annotations."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(progn
        (emacs-devtools-mcp-deftool zulu
            "Last alphabetically."
          :read-only t
          :idempotent t
          :handler (lambda (_p) "z"))
        (emacs-devtools-mcp-deftool alpha
            "First alphabetically."
          :destructive t
          :handler (lambda (_p) "a")))
     t)
    (let* ((reply (emacs-devtools-mcp-server-default-dispatcher
                   nil 'tools/list nil))
           (tools (plist-get reply :tools)))
      (should (vectorp tools))
      (should (= 2 (length tools)))
      (should (equal "alpha" (plist-get (aref tools 0) :name)))
      (should (equal "zulu"  (plist-get (aref tools 1) :name)))
      (let ((alpha-annot (plist-get (aref tools 0) :annotations))
            (zulu-annot  (plist-get (aref tools 1) :annotations)))
        (should (eq t (plist-get alpha-annot :destructiveHint)))
        (should-not (plist-get alpha-annot :readOnlyHint))
        (should (eq t (plist-get zulu-annot :readOnlyHint)))
        (should (eq t (plist-get zulu-annot :idempotentHint)))))))

(defconst emacs-devtools-mcp-tests--golden-dir
  (expand-file-name
   "golden/"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding checked-in wire-format snapshots.")

(ert-deftest emacs-devtools-mcp-tests/tools-list-matches-golden-hash ()
  "The canonical `tools/list' JSON hashes to the checked-in golden value.
A drift here means one of two things: a tool's schema changed
without bumping `test/golden/tools-list.sha256' (so reviewers can
see the wire-shape change in the diff), or stale state from a
previous load is bleeding into the current registry (the
`with_properties' artifact discovered during planning).  Either is
worth catching loudly.

Updating the golden: re-compute with
  (secure-hash \\='sha256
   (json-serialize (edmcp--server-tools-list nil)
                   :false-object :json-false :null-object nil))
and write the new value into `test/golden/tools-list.sha256'.

Note: this test reads the *live, currently-loaded* registry rather
than allocating a fresh one -- the global registry is exactly what
the wire serves, and that is what a stale-host bug would
contaminate."
  :tags '(:fast)
  (let* ((golden-path
          (expand-file-name "tools-list.sha256"
                            emacs-devtools-mcp-tests--golden-dir))
         (golden (string-trim
                  (with-temp-buffer
                    (insert-file-contents golden-path)
                    (buffer-string))))
         (json (json-serialize (edmcp--server-tools-list nil)
                               :false-object :json-false
                               :null-object nil))
         (actual (secure-hash 'sha256 json)))
    (should (equal golden actual))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-tools-list-includes-input-schema ()
  "Every entry carries `:inputSchema'; default is `{type:object}'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(progn
        (emacs-devtools-mcp-deftool with-schema
            "Has a schema."
          :schema '(:type "object" :properties ((n . (:type "integer"))))
          :handler (lambda (_p) nil))
        (emacs-devtools-mcp-deftool no-schema
            "No schema."
          :handler (lambda (_p) nil)))
     t)
    (let* ((reply (emacs-devtools-mcp-server-default-dispatcher
                   nil 'tools/list nil))
           (tools (plist-get reply :tools)))
      (cl-loop for entry across tools
               do (should (plist-member entry :inputSchema))))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-tools-call-ping ()
  "`tools/call' for `ping' returns the canonical text content envelope."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(emacs-devtools-mcp-deftool ping
          "Reply with pong."
        :read-only t
        :idempotent t
        :handler (lambda (_p) "pong"))
     t)
    (let ((reply (emacs-devtools-mcp-server-default-dispatcher
                  nil 'tools/call '(:name "ping" :arguments nil))))
      (should (eq :json-false (plist-get reply :isError)))
      (let* ((content (plist-get reply :content))
             (block (aref content 0)))
        (should (vectorp content))
        (should (equal "text" (plist-get block :type)))
        (should (equal "pong" (plist-get block :text)))))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-tools-call-ping-with-message ()
  "`ping' with `message' argument echoes it in the reply text.
Verifies that schema-validated arguments reach the handler intact."
  :tags '(:fast)
  ;; Use the *real* ping tool registered at server load.
  (let ((reply (emacs-devtools-mcp-server-default-dispatcher
                nil 'tools/call
                '(:name "ping" :arguments (:message "hi")))))
    (should (eq :json-false (plist-get reply :isError)))
    (should (equal "pong: hi"
                   (plist-get (aref (plist-get reply :content) 0) :text)))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-unknown-method ()
  "An authenticated request with an unknown method signals -32601."
  :tags '(:fast)
  (let ((err (should-error
              (emacs-devtools-mcp-server-default-dispatcher
               nil 'no/such/method nil)
              :type 'jsonrpc-error)))
    (should (eq -32601 (alist-get 'jsonrpc-error-code (cdr err))))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-unknown-tool ()
  "`tools/call' for an unregistered name signals -32601."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (let ((err (should-error
                (emacs-devtools-mcp-server-default-dispatcher
                 nil 'tools/call '(:name "ghost" :arguments nil))
                :type 'jsonrpc-error)))
      (should (eq -32601 (alist-get 'jsonrpc-error-code (cdr err)))))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-schema-invalid-args ()
  "`tools/call' with arguments that fail validation signals -32602."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(emacs-devtools-mcp-deftool needs-int
          "Wants an integer N."
        :schema '(:type "object"
                  :properties ((n . (:type "integer")))
                  :required ("n"))
        :handler (lambda (params) (format "got %S" (plist-get params :n))))
     t)
    (let ((err (should-error
                (emacs-devtools-mcp-server-default-dispatcher
                 nil 'tools/call
                 '(:name "needs_int" :arguments (:n "string-not-int")))
                :type 'jsonrpc-error)))
      (should (eq -32602 (alist-get 'jsonrpc-error-code (cdr err)))))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-handler-error-becomes-content-block ()
  "Handler-raised errors become success replies with `isError: t'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(emacs-devtools-mcp-deftool fall-down
          "Always errors."
        :handler (lambda (_p) (error "kaboom")))
     t)
    (let ((reply (emacs-devtools-mcp-server-default-dispatcher
                  nil 'tools/call
                  '(:name "fall_down" :arguments nil))))
      (should (eq t (plist-get reply :isError)))
      (should (string-match-p "kaboom"
                              (plist-get
                               (aref (plist-get reply :content) 0)
                               :text))))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-handler-content-passthrough ()
  "Handler that returns a `:content' plist has it forwarded with `:isError'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-registry
    (eval
     '(emacs-devtools-mcp-deftool already-shaped
          "Returns a pre-shaped content envelope."
        :handler (lambda (_p)
                   (list :content
                         (vector (list :type "text" :text "ready")))))
     t)
    (let ((reply (emacs-devtools-mcp-server-default-dispatcher
                  nil 'tools/call
                  '(:name "already_shaped" :arguments nil))))
      (should (eq :json-false (plist-get reply :isError)))
      (should (equal "ready"
                     (plist-get (aref (plist-get reply :content) 0)
                                :text))))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-real-server-initialize-and-ping ()
  "End-to-end through a real server: initialize, tools/list, tools/call ping.
Drives the full pipeline -- socket accept, RPC framing, auth gate,
post-auth dispatcher -- against a connected client process."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (emacs-devtools-mcp-tests--with-client (client buf)
      (let ((token emacs-devtools-mcp-auth--token))
        (emacs-devtools-mcp-tests--client-send
         client `(:jsonrpc "2.0"
                  :id 1
                  :method "initialize"
                  :params (:_meta (:token ,token))))
        (let ((init-reply (emacs-devtools-mcp-tests--client-await-frame
                           client buf)))
          (should (plist-get init-reply :result))))
      (emacs-devtools-mcp-tests--client-send
       client '(:jsonrpc "2.0" :id 2 :method "tools/list"))
      (let* ((reply (emacs-devtools-mcp-tests--client-await-frame
                     client buf))
             (tools (plist-get (plist-get reply :result) :tools)))
        (should (cl-some (lambda (e)
                           (equal "ping" (plist-get e :name)))
                         (append tools nil))))
      (emacs-devtools-mcp-tests--client-send
       client '(:jsonrpc "2.0"
                :id 3
                :method "tools/call"
                :params (:name "ping" :arguments (:message "hi"))))
      (let ((reply (emacs-devtools-mcp-tests--client-await-frame
                    client buf)))
        (should-not (plist-get reply :error))
        (let ((result (plist-get reply :result)))
          (should (eq :json-false (plist-get result :isError)))
          (should (equal "pong: hi"
                         (plist-get (aref (plist-get result :content) 0)
                                    :text))))))))

(ert-deftest emacs-devtools-mcp-tests/relay-end-to-end-initialize ()
  "Relay round-trips an `initialize' from stdin to a real running server.
Verifies the relay injects the token from disk into `_meta.token'
so the server's auth gate accepts the request and replies."
  :tags '(:fast)
  (skip-unless (file-executable-p emacs-devtools-mcp-tests--relay-path))
  (skip-unless (executable-find "jq"))
  (skip-unless (executable-find "socat"))
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (let* ((tmpdir (getenv "XDG_RUNTIME_DIR"))
           (received (list ""))
           (stderr (generate-new-buffer " *edmcp-relay-stderr*"))
           (proc (emacs-devtools-mcp-tests--relay-start
                  (list (concat "XDG_RUNTIME_DIR=" tmpdir))
                  (lambda (s) (setcar received (concat (car received) s)))
                  stderr)))
      (unwind-protect
          (progn
            (process-send-string
             proc
             (concat
              (jsonrpc--json-encode
               '(:jsonrpc "2.0"
                 :id 1
                 :method "initialize"
                 :params (:protocolVersion "2024-11-05"
                          :capabilities (:json-empty t))))
              "\n"))
            (with-timeout (5 (error "relay produced no reply: stderr=%S"
                                    (with-current-buffer stderr (buffer-string))))
              (while (not (string-match-p "\n" (car received)))
                (accept-process-output proc 0.05)))
            (let* ((wire (car received))
                   (nl (string-search "\n" wire))
                   (line (substring wire 0 nl))
                   (reply (with-temp-buffer
                            (insert line)
                            (goto-char (point-min))
                            (jsonrpc--json-read))))
              (should (equal "2.0" (plist-get reply :jsonrpc)))
              (should (equal 1 (plist-get reply :id)))
              (should (plist-get reply :result))
              (should-not (plist-get reply :error))))
        (when (process-live-p proc)
          (process-send-eof proc)
          (with-timeout (2 nil)
            (while (process-live-p proc) (accept-process-output proc 0.05)))
          (when (process-live-p proc) (delete-process proc)))
        (kill-buffer stderr)))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-real-server-eval-elisp ()
  "End-to-end: `tools/call eval_elisp' through the real RPC server.
Exercises auth gate, dispatcher, schema validation, the `:slow'
wrapping, and the spawn-call host branch in one round-trip."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (emacs-devtools-mcp-tests--with-client (client buf)
      (let ((token emacs-devtools-mcp-auth--token))
        (emacs-devtools-mcp-tests--client-send
         client `(:jsonrpc "2.0" :id 1 :method "initialize"
                  :params (:_meta (:token ,token))))
        (emacs-devtools-mcp-tests--client-await-frame client buf))
      (emacs-devtools-mcp-tests--client-send
       client '(:jsonrpc "2.0" :id 2 :method "tools/call"
                :params (:name "eval_elisp"
                         :arguments (:form "(+ 21 21)"))))
      (let* ((reply (emacs-devtools-mcp-tests--client-await-frame
                     client buf))
             (result (plist-get reply :result)))
        (should-not (plist-get reply :error))
        (should (eq :json-false (plist-get result :isError)))
        (should (string-match-p
                 "\"value\":\"42\""
                 (plist-get (aref (plist-get result :content) 0) :text)))))))

(ert-deftest emacs-devtools-mcp-tests/dispatch-real-server-list-buffers ()
  "End-to-end: `tools/call list_buffers' returns the current buffer list."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-server-env
    (emacs-devtools-mcp-server-start)
    (emacs-devtools-mcp-tests--with-client (client buf)
      (let ((token emacs-devtools-mcp-auth--token))
        (emacs-devtools-mcp-tests--client-send
         client `(:jsonrpc "2.0" :id 1 :method "initialize"
                  :params (:_meta (:token ,token))))
        (emacs-devtools-mcp-tests--client-await-frame client buf))
      (emacs-devtools-mcp-tests--client-send
       client '(:jsonrpc "2.0" :id 2 :method "tools/call"
                :params (:name "list_buffers"
                         :arguments (:filter "\\`\\*Messages\\*\\'"))))
      (let* ((reply (emacs-devtools-mcp-tests--client-await-frame
                     client buf))
             (text (plist-get (aref (plist-get (plist-get reply :result)
                                               :content)
                                    0)
                              :text)))
        (should (string-match-p "\\*Messages\\*" text))))))

;;;; ___Redaction___
;;
;; The redaction layer drops lines mentioning auth-source/epg/tramp
;; from any *Messages* / backtrace surface before it leaves the host.
;; Defaults always apply; `emacs-devtools-mcp-redact-extra-regexps' is
;; purely additive.

(ert-deftest emacs-devtools-mcp-tests/redact-strips-default-prefixes ()
  "Lines mentioning the built-in default prefixes are removed."
  :tags '(:fast)
  (let ((input (concat "ok line\n"
                       "auth-source-search complete\n"
                       "another ok\n"
                       "epg-decrypt-string failed\n"
                       "tramp-handle-file-attributes\n"
                       "final ok")))
    (should (equal "ok line\nanother ok\nfinal ok"
                   (emacs-devtools-mcp-redact input)))))

(ert-deftest emacs-devtools-mcp-tests/redact-empty-and-nil-pass-through ()
  "`emacs-devtools-mcp-redact' is a no-op for nil and empty strings."
  :tags '(:fast)
  (should (null (emacs-devtools-mcp-redact nil)))
  (should (equal "" (emacs-devtools-mcp-redact ""))))

(ert-deftest emacs-devtools-mcp-tests/redact-extra-regexps-additive ()
  "Project-specific regexps stack on top of the defaults."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-redact-extra-regexps '("\\`SECRET:")))
    (should (equal "kept"
                   (emacs-devtools-mcp-redact
                    "kept\nSECRET: hunter2\nauth-source-banana")))))

(ert-deftest emacs-devtools-mcp-tests/redact-preserves-mid-line-mentions ()
  "Lines that merely *contain* a redacted prefix mid-line are kept.
Defaults are anchored to line-start (`^auth-source-' etc.), so a
backtrace frame whose function name happens to mention
`auth-source-' as a substring (e.g. `my-pkg-call-auth-source-foo')
no longer disappears -- which would otherwise hide the very
information the user asked for."
  :tags '(:fast)
  (let ((input (concat "calling auth-source-foo here\n"
                       "frame: epg-thing\n"
                       "frame: my-tramp-helper\n"
                       "fine line")))
    (should (equal input (emacs-devtools-mcp-redact input)))))

(ert-deftest emacs-devtools-mcp-tests/redact-line-start-prefix-still-dropped ()
  "Line-start matches are still dropped after the anchoring fix."
  :tags '(:fast)
  (let ((input (concat "auth-source-search: foo\n"
                       "epg-decrypt-string failed\n"
                       "tramp-handle-file-attributes\n"
                       "kept")))
    (should (equal "kept" (emacs-devtools-mcp-redact input)))))

(ert-deftest emacs-devtools-mcp-tests/redact-handles-backtrace-frames ()
  "Indented `(auth-source-...)' frames in backtraces are scrubbed.
Real backtrace lines from `debug' / `backtrace-frame' typically
look like \"  (auth-source-search ...)\", so the default regexps
must tolerate leading whitespace and an opening paren."
  :tags '(:fast)
  (let ((input (concat "(auth-source-search t)\n"
                       "  (auth-source-search t)\n"
                       "\t(epg-decrypt-string foo)\n"
                       " (tramp-handle-file-attributes path)\n"
                       "kept frame\n"
                       "  (some-other-fn 1 2)")))
    (should (equal "kept frame\n  (some-other-fn 1 2)"
                   (emacs-devtools-mcp-redact input)))))

(ert-deftest emacs-devtools-mcp-tests/redact-keeps-substring-frame-names ()
  "Frames whose name *contains* a redacted prefix mid-token are kept.
A backtrace entry like `(my-pkg-call-auth-source-foo ...)' would
disappear if the regex weren't anchored to a leading whitespace /
paren run -- this test pins the boundary."
  :tags '(:fast)
  (let ((input "  (my-pkg-call-auth-source-foo arg)"))
    (should (equal input (emacs-devtools-mcp-redact input)))))

(ert-deftest emacs-devtools-mcp-tests/redact-rejects-invalid-extra-regexp ()
  "Bad user regex in `redact-extra-regexps' fails with a clear `user-error'.
Pre-fix, `string-match-p' would signal `invalid-regexp' deep
inside the redaction loop on the first tool that produced output;
the agent saw a stack frame from the helper, not the offending
config line.  Validation now happens up-front and names the bad
pattern."
  :tags '(:fast)
  (let* ((emacs-devtools-mcp-redact-extra-regexps '("["))
         (err (should-error
               (emacs-devtools-mcp-redact "auth-source-foo\nkept")
               :type 'user-error)))
    (should (string-match-p "Invalid redaction regexp"
                            (error-message-string err)))
    (should (string-match-p "\\[" (error-message-string err)))))

(ert-deftest emacs-devtools-mcp-tests/redact-rejects-non-string-pattern ()
  "Non-string entries in `redact-extra-regexps' are rejected loudly."
  :tags '(:fast)
  (let* ((emacs-devtools-mcp-redact-extra-regexps '(42))
         (err (should-error
               (emacs-devtools-mcp-redact "auth-source-foo")
               :type 'user-error)))
    (should (string-match-p "not a string"
                            (error-message-string err)))))

(ert-deftest emacs-devtools-mcp-tests/redact-handles-empty-extra-regexps ()
  "An empty extra-regexps list leaves the default behavior intact.
Validation must not introduce a regression for the common case of
`emacs-devtools-mcp-redact-extra-regexps' set to its default `nil'."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-redact-extra-regexps nil))
    (should (equal "kept"
                   (emacs-devtools-mcp-redact "auth-source-foo\nkept")))))

;;;; ___Random hex___

;; Regression: an earlier implementation read `/dev/urandom' via
;; `insert-file-contents-literally' with a BEG/END range, which silently
;; returns zero bytes on character devices.  Every token then came from
;; the `(random)' fallback, accompanied by a warning.  These tests pin
;; down both that the primary path actually produces N bytes of entropy
;; *without* tripping the warning, and that the fallback still works
;; when the subprocess is unavailable.

(ert-deftest emacs-devtools-mcp-tests/random-hex-returns-2n-hex-chars ()
  "Tokens are 2*N lowercase hex chars and vary across calls."
  :tags '(:fast)
  (let ((a (emacs-devtools-mcp-random-hex 16))
        (b (emacs-devtools-mcp-random-hex 16)))
    (should (= 32 (length a)))
    (should (= 32 (length b)))
    (should (string-match-p "\\`[0-9a-f]+\\'" a))
    (should (string-match-p "\\`[0-9a-f]+\\'" b))
    ;; Two consecutive 16-byte draws colliding has probability 2^-128;
    ;; if this ever fails, buy a lottery ticket.
    (should-not (equal a b))))

(ert-deftest emacs-devtools-mcp-tests/random-hex-primary-path-is-silent ()
  "On a working system the urandom path runs without warning."
  :tags '(:fast)
  (skip-unless (file-readable-p "/dev/urandom"))
  (skip-unless (executable-find "head"))
  (let ((warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (let ((token (emacs-devtools-mcp-random-hex 16)))
        (should (= 32 (length token)))
        (should (null warnings))))))

(ert-deftest emacs-devtools-mcp-tests/random-hex-falls-back-on-subprocess-failure ()
  "If the subprocess fails, fallback silently returns 2*N chars.
The earlier behaviour was to fire a `display-warning' on every
fallback, which polluted *Warnings* with a stale entry whenever
`/dev/urandom' was momentarily unreadable.  The fallback path is
correctness-equivalent (only the entropy source weakens), so the
warning is gone."
  :tags '(:fast)
  (let ((warnings nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (signal 'file-error '("simulated failure"))))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (let ((token (emacs-devtools-mcp-random-hex 8)))
        (should (= 16 (length token)))
        (should (string-match-p "\\`[0-9a-f]+\\'" token))
        (should (null warnings))))))

(ert-deftest emacs-devtools-mcp-tests/random-hex-falls-back-on-short-read ()
  "If the subprocess returns fewer bytes than requested, fall back silently."
  :tags '(:fast)
  (let ((warnings nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (_program _infile destination &rest _args)
                 ;; Pretend success but only deliver one byte.
                 (let ((buf (if (consp destination) (car destination)
                              destination)))
                   (when (bufferp buf)
                     (with-current-buffer buf (insert "X"))))
                 0))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (let ((token (emacs-devtools-mcp-random-hex 16)))
        (should (= 32 (length token)))
        (should (null warnings))))))

;;;; ___Cursor store___

(ert-deftest emacs-devtools-mcp-tests/cursor-roundtrip ()
  "A stored continuation comes back exactly once and is then forgotten."
  :tags '(:fast)
  (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
    (let ((tok (emacs-devtools-mcp--cursor-store '(a b c))))
      (should (stringp tok))
      ;; 16 random bytes rendered as hex.
      (should (= 32 (length tok)))
      (should (equal '(a b c) (emacs-devtools-mcp--cursor-fetch tok)))
      (should (null (emacs-devtools-mcp--cursor-fetch tok))))))

(ert-deftest emacs-devtools-mcp-tests/cursor-fetch-missing-is-nil ()
  "Unknown tokens return nil instead of erroring."
  :tags '(:fast)
  (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
    (should (null (emacs-devtools-mcp--cursor-fetch "deadbeef")))))

(ert-deftest emacs-devtools-mcp-tests/cursor-cleanup-drops-expired ()
  "Cleanup respects the TTL and removes stale entries."
  :tags '(:fast)
  (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal))
        (emacs-devtools-mcp-cursor-ttl-seconds 1))
    ;; Inject a fake expired entry directly so we don't have to sleep.
    (puthash "old" (cons (- (float-time) 60) '(stale)) emacs-devtools-mcp--cursors)
    (puthash "new" (cons (float-time) '(fresh)) emacs-devtools-mcp--cursors)
    (emacs-devtools-mcp--cursor-cleanup)
    (should (null (gethash "old" emacs-devtools-mcp--cursors)))
    (should (consp (gethash "new" emacs-devtools-mcp--cursors)))))

(ert-deftest emacs-devtools-mcp-tests/paginate-no-cursor-fits-in-page ()
  "When all items fit the first page, no next-cursor is allocated."
  :tags '(:fast)
  (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
    (pcase-let ((`(,page ,next)
                 (emacs-devtools-mcp--paginate '(a b c) 10 nil)))
      (should (equal '(a b c) page))
      (should (null next)))))

(ert-deftest emacs-devtools-mcp-tests/paginate-no-cursor-allocates-next ()
  "When items overflow the page, a fresh cursor token is returned."
  :tags '(:fast)
  (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
    (pcase-let ((`(,page ,next)
                 (emacs-devtools-mcp--paginate '(a b c d e) 2 nil)))
      (should (equal '(a b) page))
      (should (stringp next))
      (should (equal '(c d e)
                     (emacs-devtools-mcp--cursor-fetch next))))))

(ert-deftest emacs-devtools-mcp-tests/paginate-with-cursor-resumes ()
  "Subsequent calls fetch the saved tail and continue paging."
  :tags '(:fast)
  (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
    (pcase-let* ((`(,_ ,c1)
                  (emacs-devtools-mcp--paginate '(1 2 3 4 5) 2 nil))
                 (`(,page2 ,c2)
                  (emacs-devtools-mcp--paginate nil 2 c1)))
      (should (equal '(3 4) page2))
      (should (stringp c2))
      (let ((tail (emacs-devtools-mcp--cursor-fetch c2)))
        (should (equal '(5) tail))))))

(ert-deftest emacs-devtools-mcp-tests/paginate-bogus-cursor-signals-32602 ()
  "An unknown cursor token raises a JSON-RPC `-32602' rather than `()'.
A silent empty page would be indistinguishable from end-of-iteration
and would cause the agent to terminate its scan early -- losing the
remainder of the data without any indication that the cursor was
junk.  Pinning the loud failure here means the contract holds for
every paginating tool that flows through `emacs-devtools-mcp--paginate'."
  :tags '(:fast)
  (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
    (let ((err (should-error
                (emacs-devtools-mcp--paginate '(a b c) 2 "deadbeef")
                :type 'jsonrpc-error)))
      (should (= -32602 (alist-get 'jsonrpc-error-code (cdr err)))))))

(ert-deftest emacs-devtools-mcp-tests/paginate-consumed-cursor-rejected-on-reuse ()
  "Cursors are single-use: the second fetch of the same token errors.
Without this contract a buggy client could double-page over the
same window and never advance, or worse, silently re-emit a page
the user already saw.  We pop the entry on first fetch (see
`emacs-devtools-mcp--cursor-fetch') so the second call must hit
the bogus-cursor branch and raise `-32602'."
  :tags '(:fast)
  (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
    (pcase-let* ((`(,_ ,c1)
                  (emacs-devtools-mcp--paginate '(1 2 3 4 5) 2 nil)))
      (should (stringp c1))
      ;; First reuse: legitimate continuation, succeeds.
      (pcase-let ((`(,page ,_) (emacs-devtools-mcp--paginate nil 2 c1)))
        (should (equal '(3 4) page)))
      ;; Second reuse: cursor was consumed by the previous call.
      (let ((err (should-error
                  (emacs-devtools-mcp--paginate nil 2 c1)
                  :type 'jsonrpc-error)))
        (should (= -32602 (alist-get 'jsonrpc-error-code (cdr err))))))))

(ert-deftest emacs-devtools-mcp-tests/paginating-handlers-reject-bogus-cursor ()
  "Every paginating handler propagates the cursor-store failure as `-32602'.
A regression here would mean the handler called `cursor-fetch'
directly (which returns nil for unknown tokens) instead of routing
through `--paginate' (which signals).  Either path returns an
empty page on bogus input -- which is indistinguishable from
end-of-iteration to the agent.  Loud failure is the contract; we
pin every paginating tool to it."
  :tags '(:fast)
  (dolist (case `((edmcp--tools-list-buffers (:cursor "deadbeef"))
                  (edmcp--tools-list-messages (:cursor "deadbeef"))
                  (edmcp--tools-list-warnings (:cursor "deadbeef"))
                  (edmcp--tools-list-faces (:cursor "deadbeef"))
                  (edmcp--tools-describe-keymap
                   (:keymap "global-map" :cursor "deadbeef"))
                  (edmcp--tools-spawn-list (:cursor "deadbeef"))))
    (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
      (let ((err (should-error
                  (funcall (car case) (cadr case))
                  :type 'jsonrpc-error)))
        (should (= -32602
                   (alist-get 'jsonrpc-error-code (cdr err))))))))

(ert-deftest emacs-devtools-mcp-tests/paginate-cross-tool-cursor-fungible ()
  "Cursors are tool-agnostic by design: a token from tool A resumes in B.
This pins the existing contract.  The cursor store keys by token
only, not by issuing tool, and the `paginate' helper has no way to
know which tool produced the saved tail.  If we ever decide to
scope cursors to a tool name, this test should flip from a positive
assertion to `should-error', and the change to the contract will
be visible in the diff."
  :tags '(:fast)
  (let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
    ;; Tool A allocates a cursor.
    (pcase-let* ((`(,_ ,tok)
                  (emacs-devtools-mcp--paginate '(x y z) 1 nil)))
      (should (stringp tok))
      ;; Tool B fetches that cursor with a different page size.
      (pcase-let ((`(,page ,_) (emacs-devtools-mcp--paginate nil 5 tok)))
        ;; Whatever tool A had stashed comes back, page size honored.
        (should (equal '(y z) page))))))

;;;; ___Spawn dispatch (host)___

(ert-deftest emacs-devtools-mcp-tests/spawn-call-host-evaluates-form ()
  "Host target evaluates the form lexically and returns its value."
  :tags '(:fast)
  (should (equal 7 (emacs-devtools-mcp-spawn-call '(:host t) '(+ 3 4))))
  (should (equal 7 (emacs-devtools-mcp-spawn-call nil '(+ 3 4)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-call-unknown-handle-signals ()
  "Routing to a `:spawn HANDLE' that is unregistered raises the spawn error."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-spawn--handles (make-hash-table :test 'equal)))
    (let ((err (should-error
                (emacs-devtools-mcp-spawn-call '(:spawn "nope") '(+ 1 1))
                :type 'emacs-devtools-mcp-spawn-error)))
      (should (string-match-p "unknown handle" (cadr err))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-call-invalid-target-signals ()
  "Targets that match neither host nor spawn raise the spawn error."
  :tags '(:fast)
  (should-error
   (emacs-devtools-mcp-spawn-call '(:bogus t) '(+ 1 1))
   :type 'emacs-devtools-mcp-spawn-error))

;;;; ___Spawn lifecycle___
;;
;; Pure unit tests for spawn helpers (validators, handle hash, parse-reply,
;; tool registration).  Real-daemon tests are tagged `:daemon' and live
;; below behind a fixture that gates on `executable-find'.

(defmacro emacs-devtools-mcp-tests--with-empty-handles (&rest body)
  "Run BODY against a fresh, empty `emacs-devtools-mcp-spawn--handles'.
Restores the original hash on exit so tests don't bleed."
  (declare (indent 0) (debug t))
  `(let ((emacs-devtools-mcp-spawn--handles (make-hash-table :test 'equal)))
     ,@body))

(ert-deftest emacs-devtools-mcp-tests/spawn-validate-server-name-accepts ()
  "Server-name validator accepts strings of `[A-Za-z0-9_-]+'."
  :tags '(:fast)
  (dolist (n '("ok" "ok_name" "name-1" "edmcp-spawn-abc123" "A_B-C"))
    (should (equal n (edmcp--spawn-validate-server-name n)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-validate-server-name-rejects ()
  "Server-name validator rejects empty / shell-meta / path / unicode names."
  :tags '(:fast)
  (dolist (n '("" "with space" "with/slash" "with.dot"
               "with;semi" "with$dollar" "with`tick"
               "name\nwith\nnewline" "../up"))
    (should-error (edmcp--spawn-validate-server-name n)
                  :type 'emacs-devtools-mcp-spawn-error)))

(ert-deftest emacs-devtools-mcp-tests/spawn-alloc-handle-shape ()
  "Handles are 16 hex chars."
  :tags '(:fast)
  (let ((h (edmcp--spawn-alloc-handle)))
    (should (stringp h))
    (should (= 16 (length h)))
    (should (string-match-p "\\`[0-9a-f]+\\'" h))))

(ert-deftest emacs-devtools-mcp-tests/spawn-server-name-for-prefix ()
  "Auto server name is `edmcp-spawn-<HANDLE>'."
  :tags '(:fast)
  (let ((sn (edmcp--spawn-server-name-for "abc123")))
    (should (equal "edmcp-spawn-abc123" sn))
    (should (string-match-p edmcp--spawn-server-name-re sn))))

(ert-deftest emacs-devtools-mcp-tests/spawn-lookup-unknown-handle-signals ()
  "Looking up a missing handle raises `emacs-devtools-mcp-spawn-error'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (should-error (edmcp--spawn-lookup "nope")
                 :type 'emacs-devtools-mcp-spawn-error)))

(ert-deftest emacs-devtools-mcp-tests/spawn-touch-updates-last-used ()
  "Touch advances `:last-used' to a more-recent timestamp."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let* ((older (- (float-time) 100))
          (rec (list :handle "h" :server-name "edmcp-spawn-h"
                     :pid 1 :headless nil :init nil :attached nil
                     :created older :last-used older)))
     (puthash "h" rec emacs-devtools-mcp-spawn--handles)
     (let ((after (edmcp--spawn-touch "h")))
       (should (> (plist-get after :last-used) older))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-list-public-shape ()
  "`spawn-list' returns snake_case wire-shape plists, sorted by handle."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((now (float-time)))
     (puthash "bbb" (list :handle "bbb" :server-name "edmcp-spawn-bbb"
                          :pid 1 :headless nil :init nil :attached nil
                          :created now :last-used now)
              emacs-devtools-mcp-spawn--handles)
     (puthash "aaa" (list :handle "aaa" :server-name "edmcp-spawn-aaa"
                          :pid 2 :headless nil :init nil :attached t
                          :created now :last-used now)
              emacs-devtools-mcp-spawn--handles)
     (let ((listed (emacs-devtools-mcp-spawn-list)))
       (should (= 2 (length listed)))
       (should (equal "aaa" (plist-get (car listed) :handle)))
       (should (equal "bbb" (plist-get (cadr listed) :handle)))
       (should (equal "edmcp-spawn-aaa" (plist-get (car listed) :server_name)))
       (should (equal :json-false (plist-get (car listed) :headless)))
       (should (eq t (plist-get (car listed) :attached)))
       (should (integerp (plist-get (car listed) :idle_seconds)))
       (should (integerp (plist-get (car listed) :expires_at)))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-parse-reply-rejects-reader-eval ()
  "`#.' in daemon reply is rejected without calling `read'."
  :tags '(:fast)
  (let ((err (should-error
              (edmcp--spawn-parse-reply "#.(message \"pwn\")\n")
              :type 'emacs-devtools-mcp-spawn-error)))
    (should (string-match-p "rejected" (cadr err)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-parse-reply-empty-signals ()
  "Empty reply signals a structured error rather than `end-of-file'."
  :tags '(:fast)
  (let ((err (should-error
              (edmcp--spawn-parse-reply "")
              :type 'emacs-devtools-mcp-spawn-error)))
    (should (string-match-p "empty reply" (cadr err)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-parse-reply-unreadable-signals ()
  "Garbage that isn't valid Lisp signals an unreadable-reply error."
  :tags '(:fast)
  (let ((err (should-error
              (edmcp--spawn-parse-reply "(this is broken")
              :type 'emacs-devtools-mcp-spawn-error)))
    (should (string-match-p "unreadable" (cadr err)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-parse-reply-roundtrips ()
  "A well-formed prin1 reply round-trips back to its Lisp value."
  :tags '(:fast)
  (let* ((value '(:foo 1 :bar "two" :baz (3 4 5)))
         (raw (concat (prin1-to-string value) "\n")))
    (should (equal value (edmcp--spawn-parse-reply raw)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-tools-registered ()
  "All four spawn lifecycle tools are present in the registry."
  :tags '(:fast)
  (dolist (n '("spawn_emacs" "attach_emacs" "kill_emacs" "list_handles"))
    (should (gethash n emacs-devtools-mcp--tool-registry))))

(ert-deftest emacs-devtools-mcp-tests/spawn-tools-list-includes-all ()
  "`tools/list' includes spawn-lifecycle tools with correct annotations."
  :tags '(:fast)
  (let* ((res (edmcp--server-tools-list nil))
         (names (mapcar (lambda (e) (plist-get e :name))
                        (append (plist-get res :tools) nil))))
    (dolist (n '("spawn_emacs" "attach_emacs" "kill_emacs" "list_handles"))
      (should (member n names))))
  (let ((rec (gethash "list_handles" emacs-devtools-mcp--tool-registry)))
    (should (plist-get rec :read-only))
    (should (plist-get rec :idempotent))
    (should-not (plist-get rec :destructive)))
  (let ((rec (gethash "spawn_emacs" emacs-devtools-mcp--tool-registry)))
    (should-not (plist-get rec :read-only))
    (should (plist-get rec :destructive))
    (should-not (plist-get rec :idempotent)))
  (let ((rec (gethash "attach_emacs" emacs-devtools-mcp--tool-registry)))
    (should-not (plist-get rec :read-only))
    (should (plist-get rec :destructive))
    (should-not (plist-get rec :idempotent)))
  (let ((rec (gethash "kill_emacs" emacs-devtools-mcp--tool-registry)))
    (should-not (plist-get rec :read-only))
    (should (plist-get rec :destructive))
    (should (plist-get rec :idempotent))))

(ert-deftest emacs-devtools-mcp-tests/spawn-emacs-schema-rejects-name ()
  "`spawn_emacs' schema must not accept caller-supplied `name'.
Agent control over server names lets a malicious or buggy agent
collide with a user's daemon, which the idle reaper would then
kill -- so the field is removed from the public schema."
  :tags '(:fast)
  (let ((schema (plist-get
                 (gethash "spawn_emacs" emacs-devtools-mcp--tool-registry)
                 :schema)))
    (should-not (assq 'name (plist-get schema :properties)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-attach-max-handles-cap ()
  "Attaching past `max-handles' is rejected before probing the daemon."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((emacs-devtools-mcp-spawn-max-handles 1)
         (now (float-time))
         (probed 0))
     (cl-letf (((symbol-function 'edmcp--spawn-emacsclient-ping)
                (lambda (&rest _) (cl-incf probed) 4242)))
       (puthash "h0" (list :handle "h0" :server-name "edmcp-spawn-h0"
                           :pid 1 :headless nil :init nil :attached nil
                           :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (let ((err (should-error
                   (emacs-devtools-mcp-spawn-attach "edmcp-other")
                   :type 'emacs-devtools-mcp-spawn-error)))
         (should (string-match-p "max-handles" (cadr err))))
       (should (zerop probed))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-tool-kill-idempotent ()
  "Calling `kill_emacs' twice returns success on the second call."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((now (float-time)))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (&rest _) (cons 0 ""))))
       (puthash "h" (list :handle "h" :server-name "edmcp-spawn-h"
                          :pid 1 :headless nil :init nil :attached nil
                          :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (let ((env1 (edmcp--server-tools-call
                    nil
                    (list :name "kill_emacs"
                          :arguments (list :handle "h")))))
         (should-not (eq t (plist-get env1 :isError))))
       (let* ((env2 (edmcp--server-tools-call
                     nil
                     (list :name "kill_emacs"
                           :arguments (list :handle "h"))))
              (text (plist-get (aref (plist-get env2 :content) 0) :text)))
         (should-not (eq t (plist-get env2 :isError)))
         ;; Second call sees a handle that was dropped by the first --
         ;; reported as `unknown_handle' with `already_gone: false', so
         ;; callers can distinguish a typo from a registered-but-dead
         ;; daemon.
         (should (string-match-p "\"status\":[ ]*\"unknown_handle\"" text))
         (should (string-match-p "\"already_gone\":[ ]*false" text)))))))


(ert-deftest emacs-devtools-mcp-tests/spawn-tool-schema-rejects-bad-args ()
  "`attach-emacs' schema requires `server_name'; `kill-emacs' requires `handle'."
  :tags '(:fast)
  (should
   (emacs-devtools-mcp--validate
    (plist-get (gethash "attach_emacs" emacs-devtools-mcp--tool-registry) :schema)
    '()))
  (should-not
   (emacs-devtools-mcp--validate
    (plist-get (gethash "attach_emacs" emacs-devtools-mcp--tool-registry) :schema)
    '(:server_name "ok-name")))
  (should
   (emacs-devtools-mcp--validate
    (plist-get (gethash "kill_emacs" emacs-devtools-mcp--tool-registry) :schema)
    '())))

(ert-deftest emacs-devtools-mcp-tests/spawn-headless-rejected ()
  "Passing `:headless t' raises `not yet implemented'.  Phase 6 limitation."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((err (should-error
               (emacs-devtools-mcp-spawn-spawn :headless t)
               :type 'emacs-devtools-mcp-spawn-error)))
     (should (string-match-p "headless" (cadr err))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-bootstrap-args-load-package ()
  "`edmcp--spawn-bootstrap-args' produces argv that loads the package.

Regression: every `target: {\"spawn\": \"<handle>\"}' tool call
went out as a `(emacs-devtools-mcp-tools-*-...)' form to a daemon
launched with `emacs -Q', which had never loaded any of those
modules; emacsclient came back with `void-function'.  The
bootstrap argv adds the package directory to `load-path' and
`require's both `emacs-devtools-mcp' and
`emacs-devtools-mcp-server', the latter triggering the
eval-after-load chain that pulls in every tool subsystem."
  :tags '(:fast)
  (let* ((args (edmcp--spawn-bootstrap-args)))
    (should (member "-L" args))
    (let ((dir (cadr (member "-L" args))))
      (should (stringp dir))
      (should (file-directory-p dir))
      (should (file-exists-p
               (expand-file-name "emacs-devtools-mcp.el" dir))))
    ;; Both modules are explicitly required.  The host package's
    ;; `eval-after-load 'emacs-devtools-mcp-server' chain takes care
    ;; of pulling in the tool subsystems once `-server' loads.
    (should (cl-find-if (lambda (s)
                          (and (stringp s)
                               (string-match-p
                                "(require 'emacs-devtools-mcp)" s)))
                        args))
    (should (cl-find-if (lambda (s)
                          (and (stringp s)
                               (string-match-p
                                "(require 'emacs-devtools-mcp-server)" s)))
                        args))))

(ert-deftest emacs-devtools-mcp-tests/spawn-start-bg-daemon-injects-bootstrap ()
  "`edmcp--spawn-start-bg-daemon' actually wires the bootstrap argv in.
Captures the argv passed to `edmcp--spawn-call-process' and asserts
the load-path injection appears between the `--bg-daemon' flag and
any caller-supplied EXTRA-ARGS (so `-l USER-INIT' runs *after* the
package loads)."
  :tags '(:fast)
  (let ((captured-args nil))
    (cl-letf (((symbol-function 'edmcp--spawn-call-process)
               (lambda (_program args)
                 (setq captured-args args)
                 (cons 0 "")))
              ((symbol-function 'edmcp--spawn-wait-ready)
               (lambda (_n) 4242)))
      (edmcp--spawn-start-bg-daemon "edmcp-spawn-test" '("-l" "/tmp/x.el")))
    (should captured-args)
    (let* ((daemon-pos (cl-position-if
                        (lambda (s) (string-match-p "--bg-daemon=" s))
                        captured-args))
           (load-path-pos (cl-position "-L" captured-args :test #'equal))
           (user-init-pos (cl-position "/tmp/x.el" captured-args
                                       :test #'equal)))
      (should daemon-pos)
      (should load-path-pos)
      (should user-init-pos)
      ;; Order: --bg-daemon=NAME ... -L DIR ... -l /tmp/x.el
      (should (< daemon-pos load-path-pos))
      (should (< load-path-pos user-init-pos)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-max-handles-cap ()
  "Spawning past `max-handles' is rejected without invoking `make-process'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((emacs-devtools-mcp-spawn-max-handles 2)
         (now (float-time))
         (called 0))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (&rest _) (cl-incf called) (cons 0 ""))))
       (dotimes (i 2)
         (puthash (format "h%d" i)
                  (list :handle (format "h%d" i)
                        :server-name (format "edmcp-spawn-h%d" i)
                        :pid (+ 1000 i) :headless nil :init nil
                        :attached nil :created now :last-used now)
                  emacs-devtools-mcp-spawn--handles))
       (let ((err (should-error
                   (emacs-devtools-mcp-spawn-spawn)
                   :type 'emacs-devtools-mcp-spawn-error)))
         (should (string-match-p "max-handles" (cadr err))))
       (should (zerop called))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-init-allowlist-rejects-outside ()
  "Init path outside the allowlist is rejected before make-process."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((tmpfile (make-temp-file "edmcp-init-bad-" nil ".el")))
     (unwind-protect
         (let ((emacs-devtools-mcp-init-allowlist '("~/.config/emacs")))
           (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                     ((symbol-function 'edmcp--spawn-call-process)
                      (lambda (&rest _) (error "must not be called"))))
             (should-error (emacs-devtools-mcp-spawn-spawn :init tmpfile)
                           :type 'user-error)))
       (delete-file tmpfile)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-init-allowlist-accepts-inside ()
  "Init path under an allowlist directory is canonicalized."
  :tags '(:fast)
  (let ((dir (make-temp-file "edmcp-allow-" t)))
    (unwind-protect
        (let* ((file (expand-file-name "init.el" dir))
               (emacs-devtools-mcp-init-allowlist (list dir)))
          (write-region "(message \"ok\")\n" nil file)
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
            (let ((real (emacs-devtools-mcp-auth-validate-init-path file)))
              (should (equal real (file-truename file))))))
      (delete-directory dir t))))

(ert-deftest emacs-devtools-mcp-tests/spawn-init-allowlist-nonexistent ()
  "Nonexistent init path raises `user-error'."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-init-allowlist '("~/.emacs.d")))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
      (should-error
       (emacs-devtools-mcp-auth-validate-init-path
        "/nope/does/not/exist.el")
       :type 'user-error))))

(ert-deftest emacs-devtools-mcp-tests/spawn-init-allowlist-symlink-escape ()
  "A symlink whose target is outside the allowlist is rejected.
The allowlist here (`~/.config/emacs') matches *neither* the
expanded link path (under `/tmp') nor the resolved target (also
under `/tmp'), so the OR-of-prefixes check still rejects this
case after the bug-5 fix."
  :tags '(:fast)
  (let* ((outside (make-temp-file "edmcp-sym-out-" nil ".el"))
         (allow-dir (make-temp-file "edmcp-allow-" t))
         (link (expand-file-name "init.el" allow-dir)))
    (unwind-protect
        (let ((emacs-devtools-mcp-init-allowlist '("~/.config/emacs")))
          (write-region "(message \"out\")\n" nil outside)
          (make-symbolic-link outside link)
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
            (should-error
             (emacs-devtools-mcp-auth-validate-init-path link)
             :type 'user-error)))
      (delete-file outside)
      (delete-directory allow-dir t))))

(ert-deftest emacs-devtools-mcp-tests/spawn-init-allowlist-symlink-into-allowed-dir ()
  "Symlinks under an allowed dir resolve via the link path, not the target.

Real-world driver: NixOS / home-manager users have
`~/.config/emacs/init.el' symlinked into the read-only
`/nix/store/...' tree.  Pre-fix, the allowlist resolved the
target through `file-truename' and then prefix-checked against
`~/.config/emacs', which never matched a `/nix/store/...' real
path -- so `init_lint' / `bisect_init' / `startup_profile' were
unusable on those systems.  The fix accepts the path when *either*
its expanded form or its resolved form lies under the allowlist."
  :tags '(:fast)
  (let* ((target (make-temp-file "edmcp-sym-target-" nil ".el"))
         (allow-dir (make-temp-file "edmcp-allow-real-" t))
         (link (expand-file-name "init.el" allow-dir)))
    (unwind-protect
        (let ((emacs-devtools-mcp-init-allowlist (list allow-dir)))
          (write-region "(setq edmcp-sym-test 1)\n" nil target)
          (make-symbolic-link target link)
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
            (let ((real (emacs-devtools-mcp-auth-validate-init-path link)))
              ;; Returns the *resolved* path (truename), but the path was
              ;; accepted because the link itself is under allow-dir.
              (should (equal real (file-truename target))))))
      (delete-file target)
      (delete-directory allow-dir t))))

(ert-deftest emacs-devtools-mcp-tests/spawn-init-allowlist-real-only-match ()
  "Symmetric case: ABS off-allowlist but the truename REAL is under allowlist.
The OR-semantics in `validate-init-path' admits both the
NixOS-style case (ABS matches, REAL is in `/nix/store') and this
inverted case where the link itself sits outside the allowlist
but resolves into it.  Pins the second branch so a future
single-arm regression doesn't pass the existing tests."
  :tags '(:fast)
  (let* ((allow-dir (make-temp-file "edmcp-allow-target-" t))
         (target (expand-file-name "init.el" allow-dir))
         (link-dir (make-temp-file "edmcp-link-out-" t))
         (link (expand-file-name "shim.el" link-dir)))
    (unwind-protect
        (let ((emacs-devtools-mcp-init-allowlist (list allow-dir)))
          (write-region "(setq edmcp-real-only 1)\n" nil target)
          (make-symbolic-link target link)
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
            (let ((real (emacs-devtools-mcp-auth-validate-init-path link)))
              (should (equal real (file-truename target))))))
      (delete-file link)
      (delete-file target)
      (delete-directory allow-dir t)
      (delete-directory link-dir t))))

(ert-deftest emacs-devtools-mcp-tests/spawn-tool-list-handles-cursor ()
  "list-handles paginates with cursor when count > page size."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((emacs-devtools-mcp-handles-page-size 2)
         (now (float-time)))
     (dotimes (i 5)
       (let ((h (format "h%02d" i)))
         (puthash h (list :handle h
                          :server-name (concat "edmcp-spawn-" h)
                          :pid (+ 1000 i) :headless nil :init nil
                          :attached nil :created now :last-used now)
                  emacs-devtools-mcp-spawn--handles)))
     (let* ((p1 (edmcp--tools-spawn-list nil))
            (h1 (plist-get p1 :handles))
            (cur (plist-get p1 :next_cursor)))
       (should (= 2 (length h1)))
       (should (stringp cur))
       (let* ((p2 (edmcp--tools-spawn-list (list :cursor cur)))
              (h2 (plist-get p2 :handles))
              (cur2 (plist-get p2 :next_cursor)))
         (should (= 2 (length h2)))
         (should (stringp cur2))
         (let* ((p3 (edmcp--tools-spawn-list (list :cursor cur2)))
                (h3 (plist-get p3 :handles)))
           (should (= 1 (length h3)))
           (should-not (plist-member p3 :next_cursor))))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-reaper-kills-idle ()
  "Reaper kills handles past the idle timeout, leaves recent ones alive."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let* ((emacs-devtools-mcp-spawn-idle-timeout 60)
          (now (float-time))
          (kill-calls nil))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (_program args &optional _b)
                  (push args kill-calls) (cons 0 ""))))
       (puthash "fresh"
                (list :handle "fresh" :server-name "edmcp-spawn-fresh"
                      :pid 1 :headless nil :init nil :attached nil
                      :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (puthash "stale"
                (list :handle "stale" :server-name "edmcp-spawn-stale"
                      :pid 2 :headless nil :init nil :attached nil
                      :created (- now 1000) :last-used (- now 1000))
                emacs-devtools-mcp-spawn--handles)
       (edmcp--spawn-reaper-tick)
       (should (gethash "fresh" emacs-devtools-mcp-spawn--handles))
       (should-not (gethash "stale" emacs-devtools-mcp-spawn--handles))
       (should (cl-some (lambda (a) (member "edmcp-spawn-stale" a))
                        kill-calls))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-kill-all-empties-table ()
  "`spawn-kill-all' drops every record and cancels the reaper timer."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((now (float-time)))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (&rest _) (cons 0 ""))))
       (puthash "h1" (list :handle "h1" :server-name "edmcp-spawn-h1"
                           :pid 1 :headless nil :init nil :attached nil
                           :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (emacs-devtools-mcp-spawn-kill-all)
       (should (zerop (hash-table-count
                       emacs-devtools-mcp-spawn--handles)))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-tool-kill-unknown-handle-ok ()
  "Calling `kill-emacs' with an unknown handle returns a success envelope.
The tool is annotated `idempotentHint: true', so a call against a
never-registered handle must return ok rather than an `:isError'
envelope.  The `:status' is `\"unknown_handle\"' and `:already_gone'
is false -- the handle is gone in the sense of \"not in the
registry\", but it is distinguishable from `\"already_dead\"' (a
registered handle whose daemon stopped answering)."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let* ((env (edmcp--server-tools-call
                nil
                (list :name "kill_emacs"
                      :arguments (list :handle "ghost"))))
          (text (plist-get (aref (plist-get env :content) 0) :text)))
     (should-not (eq t (plist-get env :isError)))
     (should (string-match-p "\"status\":[ ]*\"unknown_handle\"" text))
     (should (string-match-p "\"already_gone\":[ ]*false" text)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-kill-attached-spares-daemon ()
  "Killing an attached handle drops the record without sending `kill-emacs'.
Regression: `spawn-kill' previously ran `(kill-emacs)' against
whatever daemon owned the handle's `:server-name', including
user-owned daemons registered via `attach_emacs'.  An explicit
`kill_emacs' call -- or a 30-min idle reaper sweep -- would then
murder the user's real Emacs."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((now (float-time))
         (calls nil))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (_program args &optional _b)
                  (push args calls) (cons 0 ""))))
       (puthash "att" (list :handle "att" :server-name "user-daemon"
                            :pid 1 :headless nil :init nil :attached t
                            :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (let ((dropped (emacs-devtools-mcp-spawn-kill "att")))
         (should-not (gethash "att" emacs-devtools-mcp-spawn--handles))
         (should (eq 'attached (plist-get dropped :kill-status))))
       (should-not calls)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-kill-spawned-sends-kill-emacs ()
  "Killing a non-attached handle still runs the `(kill-emacs)' RPC."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((now (float-time))
         (calls nil))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (_program args &optional _b)
                  (push args calls) (cons 0 ""))))
       (puthash "sp" (list :handle "sp" :server-name "edmcp-spawn-sp"
                           :pid 2 :headless nil :init nil :attached nil
                           :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (let ((dropped (emacs-devtools-mcp-spawn-kill "sp")))
         (should-not (gethash "sp" emacs-devtools-mcp-spawn--handles))
         (should (eq 'killed (plist-get dropped :kill-status))))
       (should (cl-some (lambda (a)
                          (and (member "edmcp-spawn-sp" a)
                               (member "(kill-emacs)" a)))
                        calls))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-kill-spawned-already-dead ()
  "Non-zero rc from emacsclient marks the kill as `already-dead'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((now (float-time)))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (&rest _) (cons 1 "no daemon"))))
       (puthash "sp" (list :handle "sp" :server-name "edmcp-spawn-sp"
                           :pid 3 :headless nil :init nil :attached nil
                           :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (let ((dropped (emacs-devtools-mcp-spawn-kill "sp")))
         (should (eq 'already-dead (plist-get dropped :kill-status))))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-reaper-skips-attached ()
  "Reaper leaves attached handles alone even when long past idle timeout.
The idle timeout is a resource cap on daemons this package
started -- not a license to reap user-owned daemons that happen
to have been registered via `attach_emacs'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let* ((emacs-devtools-mcp-spawn-idle-timeout 60)
          (now (float-time))
          (calls nil))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (_program args &optional _b)
                  (push args calls) (cons 0 ""))))
       (puthash "att-stale"
                (list :handle "att-stale" :server-name "user-daemon"
                      :pid 1 :headless nil :init nil :attached t
                      :created (- now 9999) :last-used (- now 9999))
                emacs-devtools-mcp-spawn--handles)
       (puthash "spawned-stale"
                (list :handle "spawned-stale"
                      :server-name "edmcp-spawn-spawned-stale"
                      :pid 2 :headless nil :init nil :attached nil
                      :created (- now 9999) :last-used (- now 9999))
                emacs-devtools-mcp-spawn--handles)
       (edmcp--spawn-reaper-tick)
       ;; Attached survives.
       (should (gethash "att-stale" emacs-devtools-mcp-spawn--handles))
       ;; Spawned is reaped.
       (should-not (gethash "spawned-stale"
                            emacs-devtools-mcp-spawn--handles))
       ;; No (kill-emacs) was sent against the attached daemon's name.
       (should-not (cl-some (lambda (a) (member "user-daemon" a))
                            calls))
       ;; The spawned reap did call into emacsclient.
       (should (cl-some (lambda (a)
                          (member "edmcp-spawn-spawned-stale" a))
                        calls))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-kill-all-spares-attached ()
  "`spawn-kill-all' (run from `kill-emacs-hook') leaves attached daemons alive."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((now (float-time))
         (calls nil))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (_program args &optional _b)
                  (push args calls) (cons 0 ""))))
       (puthash "att" (list :handle "att" :server-name "user-daemon"
                            :pid 1 :headless nil :init nil :attached t
                            :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (puthash "sp" (list :handle "sp" :server-name "edmcp-spawn-sp"
                           :pid 2 :headless nil :init nil :attached nil
                           :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (emacs-devtools-mcp-spawn-kill-all)
       (should-not (cl-some (lambda (a) (member "user-daemon" a)) calls))
       (should (cl-some (lambda (a)
                          (and (member "edmcp-spawn-sp" a)
                               (member "(kill-emacs)" a)))
                        calls))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-attach-rejects-double-registration ()
  "`attach-emacs' refuses to register a daemon already tracked.
Two handles for the same daemon let an explicit kill or reaper
sweep on one strand the other against a now-dead server name --
the next eval through that handle then fails with an emacsclient
connect error.  The server name is the daemon's identity; refuse."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   (let ((now (float-time))
         (probed 0))
     (cl-letf (((symbol-function 'edmcp--spawn-emacsclient-ping)
                (lambda (&rest _) (cl-incf probed) 4242)))
       (puthash "h0" (list :handle "h0" :server-name "edmcp-spawn-shared"
                           :pid 1 :headless nil :init nil :attached nil
                           :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (let ((err (should-error
                   (emacs-devtools-mcp-spawn-attach "edmcp-spawn-shared")
                   :type 'emacs-devtools-mcp-spawn-error)))
         (should (string-match-p "already tracked" (cadr err))))
       ;; Refusal happens before (and instead of) probing the daemon.
       (should (zerop probed))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-tool-kill-status-field ()
  "`kill_emacs' tool envelope carries a `status' field distinguishing states.
Three terminal states must be observable: `unknown_handle' (we
never knew about it), `killed' (RPC succeeded), `already_dead'
(handle was registered but its daemon did not answer).  The
older `already_gone' boolean stays for backwards compatibility,
true only for `already_dead' so an unknown handle is
distinguishable from a registered-but-dead one."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-empty-handles
   ;; Unknown handle -- never registered, so `already_gone' is false.
   (let* ((env (edmcp--server-tools-call
                nil
                (list :name "kill_emacs"
                      :arguments (list :handle "never-existed"))))
          (text (plist-get (aref (plist-get env :content) 0) :text)))
     (should (string-match-p "\"status\":[ ]*\"unknown_handle\"" text))
     (should (string-match-p "\"already_gone\":[ ]*false" text)))
   ;; Registered, RPC succeeds -> killed.
   (let ((now (float-time)))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (&rest _) (cons 0 ""))))
       (puthash "live" (list :handle "live" :server-name "edmcp-spawn-live"
                             :pid 1 :headless nil :init nil :attached nil
                             :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (let* ((env (edmcp--server-tools-call
                    nil
                    (list :name "kill_emacs"
                          :arguments (list :handle "live"))))
              (text (plist-get (aref (plist-get env :content) 0) :text)))
         (should (string-match-p "\"status\":[ ]*\"killed\"" text))
         (should (string-match-p "\"already_gone\":[ ]*false" text)))))
   ;; Registered, RPC fails -> already_dead.
   (let ((now (float-time)))
     (cl-letf (((symbol-function 'edmcp--spawn-call-process)
                (lambda (&rest _) (cons 1 "no daemon"))))
       (puthash "dead" (list :handle "dead" :server-name "edmcp-spawn-dead"
                             :pid 2 :headless nil :init nil :attached nil
                             :created now :last-used now)
                emacs-devtools-mcp-spawn--handles)
       (let* ((env (edmcp--server-tools-call
                    nil
                    (list :name "kill_emacs"
                          :arguments (list :handle "dead"))))
              (text (plist-get (aref (plist-get env :content) 0) :text)))
         (should (string-match-p "\"status\":[ ]*\"already_dead\"" text))
         (should (string-match-p "\"already_gone\":[ ]*true" text)))))))

(ert-deftest emacs-devtools-mcp-tests/auth-init-path-no-existence-leak ()
  "Off-allowlist paths give the same error whether the file exists or not.
Pre-fix, `validate-init-path' returned distinct errors -- `Init
file does not exist: PATH' for absent paths and `Init path PATH
outside allowlist' for present off-allowlist paths -- letting an
authenticated agent probe arbitrary filesystem locations for
presence by reading which message it got back."
  :tags '(:fast)
  (let* ((existing (make-temp-file "edmcp-leak-exists-" nil ".el"))
         (allow-dir (make-temp-file "edmcp-leak-allow-" t)))
    (unwind-protect
        (let ((emacs-devtools-mcp-init-allowlist (list allow-dir)))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
            (let ((existing-err
                   (cadr (should-error
                          (emacs-devtools-mcp-auth-validate-init-path existing)
                          :type 'user-error)))
                  (absent-err
                   (cadr (should-error
                          (emacs-devtools-mcp-auth-validate-init-path
                           "/nope/leak/probe.el")
                          :type 'user-error))))
              ;; Both must use the `outside allowlist' wording -- never
              ;; the `does not exist' wording, which would distinguish
              ;; the two cases.
              (should (string-match-p "outside allowlist" existing-err))
              (should (string-match-p "outside allowlist" absent-err))
              (should-not (string-match-p "does not exist" existing-err))
              (should-not (string-match-p "does not exist" absent-err)))))
      (delete-file existing)
      (delete-directory allow-dir t))))

(ert-deftest emacs-devtools-mcp-tests/auth-init-path-in-allowlist-still-existence-checks ()
  "An in-allowlist path that does not exist still surfaces a clear error.
The presence check is preserved for paths whose expanded form
matches an allowlist prefix -- the agent already has scope to
read those, so revealing existence costs nothing."
  :tags '(:fast)
  (let ((allow-dir (make-temp-file "edmcp-allow-exists-" t)))
    (unwind-protect
        (let ((emacs-devtools-mcp-init-allowlist (list allow-dir)))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
            (let ((err (cadr (should-error
                              (emacs-devtools-mcp-auth-validate-init-path
                               (expand-file-name "missing.el" allow-dir))
                              :type 'user-error))))
              (should (string-match-p "does not exist" err)))))
      (delete-directory allow-dir t))))

;;;; ___Spawn lifecycle (real daemon)___
;;
;; Tests tagged `:daemon' actually spawn a subordinate Emacs daemon.
;; Skipped in environments where `emacsclient' isn't on PATH.  Each
;; test cleans up its own handle in `unwind-protect' so a failure in
;; one doesn't strand a daemon for the next.

(defun emacs-devtools-mcp-tests--daemon-available-p ()
  "Return non-nil when both `emacs' and `emacsclient' are executable."
  (and (executable-find emacs-devtools-mcp-spawn-emacs-program)
       (executable-find emacs-devtools-mcp-spawn-emacsclient-program)))

(ert-deftest emacs-devtools-mcp-tests/spawn-real-daemon-eval ()
  "Spawn a real daemon, eval through it, kill, and confirm it's gone."
  :tags '(:daemon)
  (skip-unless (emacs-devtools-mcp-tests--daemon-available-p))
  (emacs-devtools-mcp-tests--with-empty-handles
   (let* ((rec (emacs-devtools-mcp-spawn-spawn))
          (handle (plist-get rec :handle))
          (sn (plist-get rec :server-name)))
     (unwind-protect
         (progn
           (should (gethash handle emacs-devtools-mcp-spawn--handles))
           (should (integerp (plist-get rec :pid)))
           (should (> (plist-get rec :pid) 0))
           ;; Eval through spawn-call routes through emacsclient.
           (should (equal 7
                          (emacs-devtools-mcp-spawn-call
                           (list :spawn handle) '(+ 3 4))))
           ;; Listing reflects the live record.
           (let* ((listed (emacs-devtools-mcp-spawn-list))
                  (entry (cl-find handle listed
                                  :key (lambda (e) (plist-get e :handle))
                                  :test #'equal)))
             (should entry)
             (should (equal sn (plist-get entry :server_name)))
             (should (>= (plist-get entry :idle_seconds) 0))
             (should (> (plist-get entry :expires_at) 0))))
       ;; Cleanup: kill if still alive.
       (when (gethash handle emacs-devtools-mcp-spawn--handles)
         (ignore-errors (emacs-devtools-mcp-spawn-kill handle))))
     (should-not (gethash handle emacs-devtools-mcp-spawn--handles))
     ;; Daemon should no longer answer.
     (should-not (edmcp--spawn-emacsclient-ping sn)))))

(ert-deftest emacs-devtools-mcp-tests/spawn-real-host-vs-spawn-parity ()
  "Built-in forms produce equal results from `(:host t)' and `(:spawn H)'.
This pins down that the dispatch path round-trips values cleanly;
package-aware parity (e.g. `tools-eval--run') requires preloading
the package in the subordinate, which is a separate enhancement."
  :tags '(:daemon)
  (skip-unless (emacs-devtools-mcp-tests--daemon-available-p))
  (emacs-devtools-mcp-tests--with-empty-handles
   (let* ((rec (emacs-devtools-mcp-spawn-spawn))
          (handle (plist-get rec :handle)))
     (unwind-protect
         (dolist (form '((+ 1 2 3)
                         (format "%d-%d" 1 2)
                         (list 'a 'b 'c)
                         (mapcar #'1+ '(1 2 3))
                         (cons :ok 42)))
           (let ((host-val (eval form t))
                 (spawn-val (emacs-devtools-mcp-spawn-call
                             (list :spawn handle) form)))
             (should (equal host-val spawn-val))))
       (when (gethash handle emacs-devtools-mcp-spawn--handles)
         (ignore-errors (emacs-devtools-mcp-spawn-kill handle)))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-real-bootstrap-loads-package ()
  "Spawned daemons have `emacs-devtools-mcp' preloaded via bootstrap argv.
Bug-2 regression test: previously the subordinate `emacs -Q' came
up bare, so any tool needing package symbols (like
`emacs-devtools-mcp-redact') failed in spawn but worked on host.
The bootstrap now appends `-L LISP-DIR --eval (require ...)' to
the daemon argv so package-aware code paths reach parity."
  :tags '(:daemon)
  (skip-unless (emacs-devtools-mcp-tests--daemon-available-p))
  (emacs-devtools-mcp-tests--with-empty-handles
   (let* ((rec (emacs-devtools-mcp-spawn-spawn))
          (handle (plist-get rec :handle))
          (target (list :spawn handle)))
     (unwind-protect
         (progn
           (should (eq t (emacs-devtools-mcp-spawn-call
                          target '(featurep 'emacs-devtools-mcp))))
           (should (eq t (emacs-devtools-mcp-spawn-call
                          target '(featurep 'emacs-devtools-mcp-server))))
           ;; A package-defined symbol is callable -- redact strips
           ;; auth-source-* lines, which is a function the host suite
           ;; covers in :fast tests.  Asserting it works *in the
           ;; subordinate* pins the bootstrap path end-to-end.
           (should (equal "kept"
                          (emacs-devtools-mcp-spawn-call
                           target
                           '(emacs-devtools-mcp-redact
                             "auth-source-search foo\nkept")))))
       (when (gethash handle emacs-devtools-mcp-spawn--handles)
         (ignore-errors (emacs-devtools-mcp-spawn-kill handle)))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-real-attach-detects ()
  "`attach-emacs' registers a daemon spawned out-of-band."
  :tags '(:daemon)
  (skip-unless (emacs-devtools-mcp-tests--daemon-available-p))
  (emacs-devtools-mcp-tests--with-empty-handles
   (let* ((sn (format "edmcp-attach-%d" (abs (random 1000000))))
          (boot-rc
           (call-process emacs-devtools-mcp-spawn-emacs-program
                         nil nil nil
                         "-Q" (format "--bg-daemon=%s" sn))))
     (should (zerop boot-rc))
     (unwind-protect
         (progn
           ;; Wait for it to come up.
           (let ((deadline (+ (float-time) 10)))
             (while (and (not (edmcp--spawn-emacsclient-ping sn))
                         (< (float-time) deadline))
               (sleep-for 0.1)))
           (should (edmcp--spawn-emacsclient-ping sn))
           ;; Attach.
           (let* ((rec (emacs-devtools-mcp-spawn-attach sn))
                  (handle (plist-get rec :handle)))
             (should (eq t (plist-get
                            (edmcp--spawn-record-public rec) :attached)))
             (should (equal 4
                            (emacs-devtools-mcp-spawn-call
                             (list :spawn handle) '(+ 2 2))))
             (emacs-devtools-mcp-spawn-kill handle)))
       ;; Defensive: kill if attach failed and daemon is still running.
       (ignore-errors
         (call-process emacs-devtools-mcp-spawn-emacsclient-program
                       nil nil nil "-s" sn "--eval" "(kill-emacs)"))))))

(ert-deftest emacs-devtools-mcp-tests/spawn-real-attach-nonexistent ()
  "`attach-emacs' to a nonexistent server signals a structured error."
  :tags '(:daemon)
  (skip-unless (emacs-devtools-mcp-tests--daemon-available-p))
  (emacs-devtools-mcp-tests--with-empty-handles
   (should-error
    (emacs-devtools-mcp-spawn-attach
     (format "edmcp-no-such-%d" (abs (random 1000000))))
    :type 'emacs-devtools-mcp-spawn-error)))

;;;; ___Eval___
;;
;; `eval-elisp' on the host: pure, deterministic, captures *Messages*
;; deltas with redaction, returns errors as a structured plist.

(ert-deftest emacs-devtools-mcp-tests/eval-run-returns-printed-value ()
  "Successful evaluation returns the prin1 form under :value."
  :tags '(:fast)
  (let ((res (emacs-devtools-mcp-tools-eval--run '(+ 1 2) 6 100)))
    (should (equal "3" (plist-get res :value)))
    (should (equal "" (plist-get res :messages)))
    (should-not (plist-get res :error))))

(ert-deftest emacs-devtools-mcp-tests/eval-run-captures-messages-delta ()
  "*Messages* output during eval is captured into the result plist."
  :tags '(:fast)
  (let ((res (emacs-devtools-mcp-tools-eval--run
              '(message "hello-from-eval-test") 6 100)))
    (should (string-match-p "hello-from-eval-test"
                            (plist-get res :messages)))))

(ert-deftest emacs-devtools-mcp-tests/eval-run-redacts-messages ()
  "Captured *Messages* lines matching redaction patterns are stripped."
  :tags '(:fast)
  (let ((res (emacs-devtools-mcp-tools-eval--run
              '(progn (message "ok-line")
                      (message "auth-source-leak %s" "secret")
                      (message "another-ok"))
              6 100)))
    (should-not (string-match-p "auth-source" (plist-get res :messages)))
    (should (string-match-p "ok-line"   (plist-get res :messages)))
    (should (string-match-p "another-ok" (plist-get res :messages)))))

(ert-deftest emacs-devtools-mcp-tests/eval-run-error-becomes-error-key ()
  "An eval signal yields :error and no :value."
  :tags '(:fast)
  (let ((res (emacs-devtools-mcp-tools-eval--run '(error "boom") 6 100)))
    (should (string-match-p "boom" (plist-get res :error)))
    (should-not (plist-get res :value))))

(ert-deftest emacs-devtools-mcp-tests/eval-run-respects-print-level ()
  "PRINT-LEVEL bounds nested-list rendering."
  :tags '(:fast)
  (let* ((res (emacs-devtools-mcp-tools-eval--run
               '(quote ((((a)))))
               1 100)))
    ;; With print-level 1, deeper structures collapse to "...".
    (should (string-match-p "\\.\\.\\." (plist-get res :value)))))

(ert-deftest emacs-devtools-mcp-tests/eval-handler-bad-form-raises-32602 ()
  "Unparseable FORM yields a JSON-RPC -32602 error envelope."
  :tags '(:fast)
  (let ((err (should-error
              (edmcp--tools-eval-elisp '(:form "(((((unbalanced"))
              :type 'jsonrpc-error)))
    (should (= -32602 (alist-get 'jsonrpc-error-code (cdr err))))))

(ert-deftest emacs-devtools-mcp-tests/eval-handler-roundtrip ()
  "End-to-end: handler reads form, evaluates, returns plist."
  :tags '(:fast)
  (let ((res (edmcp--tools-eval-elisp '(:form "(* 6 7)"))))
    (should (equal "42" (plist-get res :value)))))

;;;; ___Debug (edebug / backtrace / trace)___
;;
;; Edebug tests need a defun with discoverable source, so a tmp file
;; is written and loaded.  Trace tests use `trace-function-foreground'
;; against a fixture defun and assert against the trace buffer.

(defmacro emacs-devtools-mcp-tests--with-tmp-elisp-file (sym-binding
                                                        body-expr
                                                        &rest body)
  "Write a tmp .el defining (defun SYM () BODY-EXPR), load it, run BODY.
SYM-BINDING is bound to the symbol; the file is removed on exit
and the symbol's `symbol-function' is unbound to keep the global
namespace clean."
  (declare (indent 2) (debug t))
  `(let* ((sym (intern (format "edmcp-debug-fixture-%d"
                               (abs (random 1000000)))))
          (,sym-binding sym)
          (file (make-temp-file "edmcp-debug-fixture-" nil ".el")))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert (format "(defun %s () %S)\n"
                             (symbol-name sym)
                             ,body-expr)))
           (load file nil t)
           ,@body)
       (when (fboundp sym) (fmakunbound sym))
       (when (file-exists-p file) (delete-file file))
       (remhash sym emacs-devtools-mcp-tools-eval--edebug-originals))))

(ert-deftest emacs-devtools-mcp-tests/edebug-instrument-roundtrip ()
  "Instrument a fixture defun, then uninstrument and confirm restore."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-tmp-elisp-file sym 42
    (let* ((before (symbol-function sym))
           (res-i (emacs-devtools-mcp-tools-eval--edebug-instrument
                   (symbol-name sym))))
      (should (eq t (plist-get res-i :instrumented)))
      (should (eq :json-false (plist-get res-i :already)))
      ;; After instrument: definition should differ from the saved original.
      (should (gethash sym emacs-devtools-mcp-tools-eval--edebug-originals))
      (should-not (equal before (symbol-function sym)))
      ;; Uninstrument restores byte-equal definition.
      (let ((res-u (emacs-devtools-mcp-tools-eval--edebug-uninstrument
                    (symbol-name sym))))
        (should (eq :json-false (plist-get res-u :instrumented)))
        (should (eq t (plist-get res-u :restored)))
        (should (equal before (symbol-function sym)))
        (should-not (gethash sym
                             emacs-devtools-mcp-tools-eval--edebug-originals))))))

(ert-deftest emacs-devtools-mcp-tests/edebug-instrument-idempotent ()
  "A second instrument call on the same function is a true no-op.
The implementation MUST NOT re-run `edebug-instrument-function'
because doing so would re-wrap any advice or redefinition layered
on between the two calls -- the saved original in the hash table
would then no longer round-trip through `edebug-uninstrument'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-tmp-elisp-file sym 7
    (emacs-devtools-mcp-tools-eval--edebug-instrument (symbol-name sym))
    (let ((after-first (symbol-function sym))
          (saved-original
           (gethash sym emacs-devtools-mcp-tools-eval--edebug-originals)))
      (let ((res2 (emacs-devtools-mcp-tools-eval--edebug-instrument
                   (symbol-name sym))))
        (should (eq t (plist-get res2 :instrumented)))
        (should (eq t (plist-get res2 :already)))
        ;; The function definition must be byte-equal to after the first
        ;; call (no double-wrapping), and the saved original must be
        ;; eq-stable across the no-op.
        (should (equal after-first (symbol-function sym)))
        (should (eq saved-original
                    (gethash sym
                             emacs-devtools-mcp-tools-eval--edebug-originals)))))))

(ert-deftest emacs-devtools-mcp-tests/edebug-instrument-unknown-function ()
  "Instrumenting an unknown function signals an error."
  :tags '(:fast)
  (should-error
   (emacs-devtools-mcp-tools-eval--edebug-instrument
    "edmcp-no-such-function-xyz")))

(ert-deftest emacs-devtools-mcp-tests/edebug-uninstrument-unknown-function ()
  "Uninstrumenting an unknown function signals an error."
  :tags '(:fast)
  (should-error
   (emacs-devtools-mcp-tools-eval--edebug-uninstrument
    "edmcp-no-such-function-xyz")))

(ert-deftest emacs-devtools-mcp-tests/capture-backtrace-success-shape ()
  "Successful FORM yields :value, empty :backtrace, no :error."
  :tags '(:fast)
  (let ((res (emacs-devtools-mcp-tools-eval--capture-backtrace
              '(+ 2 3) 6 100)))
    (should (equal "5" (plist-get res :value)))
    (should (equal "" (plist-get res :backtrace)))
    (should-not (plist-get res :error))))

(ert-deftest emacs-devtools-mcp-tests/capture-backtrace-error-shape ()
  "A signaling FORM yields :error and a non-empty :backtrace."
  :tags '(:fast)
  (let ((res (emacs-devtools-mcp-tools-eval--capture-backtrace
              '(error "boom-from-test") 6 100)))
    (should (string-match-p "boom-from-test" (plist-get res :error)))
    (should (stringp (plist-get res :backtrace)))
    (should (> (length (plist-get res :backtrace)) 0))
    (should-not (plist-get res :value))))

(ert-deftest emacs-devtools-mcp-tests/capture-backtrace-redacts-messages ()
  "*Messages* delta in the backtrace result is redacted."
  :tags '(:fast)
  (let ((res (emacs-devtools-mcp-tools-eval--capture-backtrace
              '(progn (message "auth-source-leak %s" "secret")
                      (message "ok-line")
                      42)
              6 100)))
    (should-not (string-match-p "auth-source"
                                (plist-get res :messages)))
    (should (string-match-p "ok-line" (plist-get res :messages)))))

(ert-deftest emacs-devtools-mcp-tests/capture-backtrace-bad-form-raises-32602 ()
  "Unparseable FORM yields a JSON-RPC -32602 error from the handler."
  :tags '(:fast)
  (let ((err (should-error
              (edmcp--tools-capture-backtrace '(:form "(((unbalanced"))
              :type 'jsonrpc-error)))
    (should (= -32602 (alist-get 'jsonrpc-error-code (cdr err))))))

(ert-deftest emacs-devtools-mcp-tests/trace-function-roundtrip ()
  "Trace a fixture function, call it, untrace, and confirm emission stops.
In batch mode `trace--insert' redirects to `*Messages*' (because
`noninteractive' is t), so the assertion reads from that buffer.
Interactive Emacs writes to the named trace buffer; the wire shape
of the result plist is asserted independent of the underlying
delivery channel."
  :tags '(:fast)
  (let* ((sym (intern (format "edmcp-trace-fixture-%d"
                              (abs (random 1000000)))))
         (buf-name (format " *edmcp-trace-test-%d*"
                           (abs (random 1000000)))))
    (defalias sym (lambda (x) (* x 2)))
    (unwind-protect
        (let ((messages-buf (get-buffer "*Messages*")))
          (let ((res (emacs-devtools-mcp-tools-eval--trace-function
                      (symbol-name sym) buf-name)))
            (should (equal (symbol-name sym) (plist-get res :function)))
            (should (equal buf-name (plist-get res :buffer))))
          ;; Capture *Messages* delta around the traced call --
          ;; trace.el writes here in batch.
          (let* ((start (with-current-buffer messages-buf (point-max)))
                 (_ (funcall sym 21))
                 (delta (with-current-buffer messages-buf
                          (buffer-substring-no-properties
                           start (point-max)))))
            (should (string-match-p (regexp-quote (symbol-name sym))
                                    delta)))
          ;; Untrace; new calls must not extend the *Messages* delta
          ;; with a trace line.
          (let* ((res-u (emacs-devtools-mcp-tools-eval--untrace-function
                         (symbol-name sym)))
                 (start (with-current-buffer messages-buf (point-max)))
                 (_ (funcall sym 33))
                 (delta (with-current-buffer messages-buf
                          (buffer-substring-no-properties
                           start (point-max)))))
            (should (equal (symbol-name sym) (plist-get res-u :function)))
            (should-not (string-match-p (regexp-quote (symbol-name sym))
                                        delta))))
      (when (get-buffer buf-name) (kill-buffer buf-name))
      (when (fboundp sym) (fmakunbound sym)))))

(ert-deftest emacs-devtools-mcp-tests/trace-function-unknown-signals ()
  "Tracing an unknown function signals an error."
  :tags '(:fast)
  (should-error
   (emacs-devtools-mcp-tools-eval--trace-function
    "edmcp-no-such-function-xyz" nil)))

(ert-deftest emacs-devtools-mcp-tests/trace-log-paginates ()
  "trace-log returns lines paginated by the cursor store."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (let ((buf-name (format "*trace-output-edmcp-test-%d*"
                            (abs (random 1000000)))))
      (unwind-protect
          (let ((emacs-devtools-mcp-trace-log-page-size 2))
            (with-current-buffer (get-buffer-create buf-name)
              (erase-buffer)
              (insert "line-1\nline-2\nline-3\nline-4\nline-5"))
            (let* ((p1 (edmcp--tools-trace-log
                        (list :buffer buf-name)))
                   (l1 (plist-get p1 :lines))
                   (cur (plist-get p1 :next_cursor)))
              (should (= 2 (length l1)))
              (should (stringp cur))
              (let* ((p2 (edmcp--tools-trace-log
                          (list :buffer buf-name :cursor cur)))
                     (l2 (plist-get p2 :lines))
                     (cur2 (plist-get p2 :next_cursor)))
                (should (= 2 (length l2)))
                (should (stringp cur2))
                (let* ((p3 (edmcp--tools-trace-log
                            (list :buffer buf-name :cursor cur2)))
                       (l3 (plist-get p3 :lines)))
                  (should (= 1 (length l3)))
                  (should-not (plist-member p3 :next_cursor))))))
        (when (get-buffer buf-name) (kill-buffer buf-name))))))

(ert-deftest emacs-devtools-mcp-tests/trace-log-missing-buffer-signals ()
  "trace-log against a nonexistent (but well-named) buffer signals an error."
  :tags '(:fast)
  (should-error
   (emacs-devtools-mcp-tools-eval--trace-log-lines
    "*trace-output-edmcp-no-such-buffer-zzz*" nil)))

(ert-deftest emacs-devtools-mcp-tests/trace-log-rejects-non-trace-buffer ()
  "trace-log refuses buffer names that don't match the trace pattern.
Without this guard, trace-log would double as an arbitrary
buffer-read primitive and bypass the redaction layer."
  :tags '(:fast)
  (let* ((buf (get-buffer-create "*Messages*"))
         (err (should-error
               (emacs-devtools-mcp-tools-eval--trace-log-lines
                "*Messages*" nil)
               :type 'error)))
    (ignore buf)
    (should (string-match-p "Refusing to read non-trace buffer"
                            (error-message-string err))))
  (should-error
   (emacs-devtools-mcp-tools-eval--trace-log-lines "scratch" nil)))

(ert-deftest emacs-devtools-mcp-tests/trace-log-redacts-secrets ()
  "trace-log scrubs auth-source/epg/tramp prefixes before returning."
  :tags '(:fast)
  (let ((buf-name (format "*trace-output-edmcp-redact-%d*"
                          (abs (random 1000000)))))
    (unwind-protect
        (progn
          (with-current-buffer (get-buffer-create buf-name)
            (erase-buffer)
            (insert "auth-source-search :host fastmail.com :secret SHHH\n"
                    "epg-decrypt-string \"hunter2\"\n"
                    "harmless line\n"))
          (let ((lines (emacs-devtools-mcp-tools-eval--trace-log-lines
                        buf-name 4096)))
            (should (cl-every (lambda (l) (not (string-match-p "auth-source-" l)))
                              lines))
            (should (cl-every (lambda (l) (not (string-match-p "epg-" l)))
                              lines))
            (should (cl-find-if (lambda (l) (string-match-p "harmless" l))
                                lines))))
      (when (get-buffer buf-name) (kill-buffer buf-name)))))

(ert-deftest emacs-devtools-mcp-tests/trace-log-truncates-long-lines ()
  "trace-log clamps lines longer than the per-line cap."
  :tags '(:fast)
  (let ((buf-name (format "*trace-output-edmcp-cap-%d*"
                          (abs (random 1000000)))))
    (unwind-protect
        (progn
          (with-current-buffer (get-buffer-create buf-name)
            (erase-buffer)
            (insert (make-string 10000 ?x))
            (insert "\nshort"))
          (let* ((lines (emacs-devtools-mcp-tools-eval--trace-log-lines
                         buf-name 100))
                 (first (car lines)))
            (should (string-match-p "\\[truncated [0-9]+ bytes\\]" first))
            (should (< (length first) 200))
            (should (equal "short" (cadr lines)))))
      (when (get-buffer buf-name) (kill-buffer buf-name)))))

(ert-deftest emacs-devtools-mcp-tests/debug-tools-registered ()
  "All six debugger tools are present in the registry with annotations."
  :tags '(:fast)
  (dolist (n '("edebug_instrument" "edebug_uninstrument"
               "capture_backtrace" "trace_function"
               "untrace_function" "trace_log"))
    (should (gethash n emacs-devtools-mcp--tool-registry)))
  (let ((rec (gethash "trace_log" emacs-devtools-mcp--tool-registry)))
    (should (plist-get rec :read-only))
    (should (plist-get rec :idempotent))
    (should-not (plist-get rec :destructive)))
  (let ((rec (gethash "capture_backtrace" emacs-devtools-mcp--tool-registry)))
    (should-not (plist-get rec :read-only))
    (should (plist-get rec :destructive))
    (should-not (plist-get rec :idempotent))))

(ert-deftest emacs-devtools-mcp-tests/debug-tools-unknown-fn-envelope ()
  "Each function-keyed debugger tool returns `:isError t' for unknown names.
The dispatcher's `condition-case' must convert the underlying
`error' into an MCP error envelope (not a JSON-RPC -32603) so the
client sees a structured tool failure."
  :tags '(:fast)
  (dolist (name '("edebug_instrument" "edebug_uninstrument"
                  "trace_function" "untrace_function"))
    (let* ((env (edmcp--server-tools-call
                 nil
                 (list :name name
                       :arguments (list :function "edmcp-no-such-fn-xyz")))))
      (should (eq t (plist-get env :isError)))
      (let* ((blocks (plist-get env :content))
             (text (and blocks (plist-get (aref blocks 0) :text))))
        (should (stringp text))
        (should (string-match-p "edmcp-no-such-fn-xyz" text))))))

(ert-deftest emacs-devtools-mcp-tests/untrace-function-on-untraced-ok ()
  "untrace-function returns success for a function that was never traced.
This is the documented idempotent contract on the wire."
  :tags '(:fast)
  (defalias 'edmcp-tests--never-traced (lambda () 'ok))
  (unwind-protect
      (let ((res (emacs-devtools-mcp-tools-eval--untrace-function
                  "edmcp-tests--never-traced")))
        (should (equal "edmcp-tests--never-traced"
                       (plist-get res :function))))
    (fmakunbound 'edmcp-tests--never-traced)))

(ert-deftest emacs-devtools-mcp-tests/capture-backtrace-truncates-large ()
  "Oversized backtraces are head-truncated rather than dropped entirely.
The signaling frames at the top of the stack are the useful ones;
we keep those and append a `[truncated N bytes from tail]' marker.
Sets the cap below the empirical size of even the shortest
captured backtrace to force truncation regardless of how many
frames the runtime records."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-backtrace-max-bytes 8))
    (let ((res (emacs-devtools-mcp-tools-eval--capture-backtrace
                '(error "boom-from-cap-test") 6 100)))
      (should (string-match-p "boom-from-cap-test"
                              (plist-get res :error)))
      (let ((bt (plist-get res :backtrace)))
        (should (stringp bt))
        (should (string-match-p "\\[truncated [0-9]+ bytes from tail\\]" bt))
        ;; Capped near the configured limit (allow trailing marker overhead).
        (should (< (length bt) 256))))))

(ert-deftest emacs-devtools-mcp-tests/capture-backtrace-trims-mcp-plumbing ()
  "Captured backtrace stops at the marker; no MCP dispatch frames leak.
The walker keys off `edmcp--capture-backtrace-eval' and stops the
moment it sees that frame, so nothing older -- `condition-case'
wrappers, jsonrpc, deftool, the server's tools-call dispatcher --
appears in the returned text.  This regression test asserts the
trimming directly: it calls `capture-backtrace' with a deeply nested
form and confirms the marker function name and known plumbing
prefixes are absent from `:backtrace'."
  :tags '(:fast)
  (let* ((res (emacs-devtools-mcp-tools-eval--capture-backtrace
               '(let nil (error "boom-trim-test")) 6 100))
         (bt (plist-get res :backtrace)))
    (should (stringp bt))
    (should (> (length bt) 0))
    (should-not (string-match-p "edmcp--capture-backtrace-eval" bt))
    (should-not (string-match-p "edmcp--server-tools-call" bt))
    (should-not (string-match-p "jsonrpc" bt))
    ;; The signaling frame is at the top.
    (should (string-match-p "\\`(error " bt))))

;;;; ___Buffer tools___

(defmacro emacs-devtools-mcp-tests--with-fresh-cursors (&rest body)
  "Run BODY with a fresh cursor store so paginate state is isolated."
  (declare (indent 0) (debug t))
  `(let ((emacs-devtools-mcp--cursors (make-hash-table :test 'equal)))
     ,@body))

(ert-deftest emacs-devtools-mcp-tests/list-buffers-returns-current ()
  "`list-buffers' includes the current buffer with name/mode/size."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (with-temp-buffer
      (rename-buffer "edmcp-list-buffers-fixture" t)
      (insert "abcde")
      (let* ((res (edmcp--tools-list-buffers '()))
             (vec (plist-get res :buffers))
             (entry (cl-find-if
                     (lambda (e)
                       (string= "edmcp-list-buffers-fixture"
                                (plist-get e :name)))
                     (append vec nil))))
        (should entry)
        (should (= 5 (plist-get entry :size)))))))

(ert-deftest emacs-devtools-mcp-tests/list-buffers-filter-narrows ()
  "The :filter regex restricts which buffers are emitted."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (let ((res (edmcp--tools-list-buffers
                '(:filter "\\`edmcp-no-such-buffer-pattern\\'"))))
      (should (= 0 (length (plist-get res :buffers)))))))

(ert-deftest emacs-devtools-mcp-tests/list-buffers-paginates ()
  "When more buffers exist than the page size, a next_cursor is returned."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (let ((emacs-devtools-mcp-buffer-list-page-size 1)
          (extra-bufs nil))
      (unwind-protect
          (progn
            (push (generate-new-buffer "edmcp-paginate-1") extra-bufs)
            (push (generate-new-buffer "edmcp-paginate-2") extra-bufs)
            (let ((res (edmcp--tools-list-buffers
                        '(:filter "\\`edmcp-paginate-"))))
              (should (= 1 (length (plist-get res :buffers))))
              (should (stringp (plist-get res :next_cursor)))))
        (mapc #'kill-buffer extra-bufs)))))

(ert-deftest emacs-devtools-mcp-tests/buffer-state-reports-point-and-mode ()
  "`buffer-state' returns point/line/column/mode for a known buffer."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-buffer-state-fixture" t)
    (insert "first\nsecond")
    (goto-char (point-max))
    (let ((res (edmcp--tools-buffer-state
                '(:buffer "edmcp-buffer-state-fixture"))))
      (should (equal "edmcp-buffer-state-fixture" (plist-get res :name)))
      ;; "first\nsecond" is 12 chars; point at end is 13 (1-based).
      (should (= 13 (plist-get res :point)))
      (should (= 12 (plist-get res :size)))
      (should (= 2 (plist-get res :line))))))

(ert-deftest emacs-devtools-mcp-tests/buffer-state-missing-buffer-errors ()
  "Asking for a nonexistent buffer raises a regular error."
  :tags '(:fast)
  (should-error
   (edmcp--tools-buffer-state '(:buffer "edmcp-no-such-buffer-here"))))

(ert-deftest emacs-devtools-mcp-tests/buffer-state-killed-mid-call-envelopes ()
  "A buffer killed between schema-validate and handler emits a tool envelope.
Goes through the full dispatcher so we exercise the
`condition-case' wrapper -- the bare `error' that the handler
signals when `get-buffer' returns nil must reach the wire as
`isError: true' with a content block, not bubble out as a
JSON-RPC -32603."
  :tags '(:fast)
  (let* ((name (format "edmcp-killed-%d" (random 100000)))
         (_ (with-current-buffer (get-buffer-create name)
              (insert "alive")))
         (orig-fn (symbol-function 'get-buffer))
         (env nil))
    ;; Stub `get-buffer' so it pretends the buffer was killed between
    ;; the schema validator and the handler body.
    (cl-letf (((symbol-function 'get-buffer)
               (lambda (n &rest args)
                 (if (and (stringp n) (equal n name))
                     nil
                   (apply orig-fn n args)))))
      (setq env (edmcp--server-tools-call
                 nil
                 (list :name "buffer_state"
                       :arguments (list :buffer name)))))
    (when (get-buffer name) (kill-buffer name))
    (should (eq t (plist-get env :isError)))
    (let* ((blocks (plist-get env :content))
           (text (and blocks (plist-get (aref blocks 0) :text))))
      (should (stringp text))
      (should (string-match-p "Buffer not found" text)))))

(ert-deftest emacs-devtools-mcp-tests/buffer-substring-returns-text ()
  "Plain `buffer-substring' returns the requested slice without truncation."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-substring-fixture" t)
    (insert "abcdef")
    (let ((res (edmcp--tools-buffer-substring
                '(:buffer "edmcp-substring-fixture"
                  :start 2 :end 5))))
      (should (equal "bcd" (plist-get res :text)))
      (should (eq :json-false (plist-get res :truncated))))))

(ert-deftest emacs-devtools-mcp-tests/buffer-substring-truncates-with-next-offset ()
  "Hitting the byte cap sets `truncated: t' and offers `next_offset'."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-substring-cap" t)
    (insert (make-string 100 ?x))
    (let ((res (edmcp--tools-buffer-substring
                '(:buffer "edmcp-substring-cap"
                  :start 1 :end 101 :max_bytes 10))))
      (should (= 10 (length (plist-get res :text))))
      (should (eq t (plist-get res :truncated)))
      (should (= 11 (plist-get res :next_offset))))))

(ert-deftest emacs-devtools-mcp-tests/buffer-substring-missing-buffer-errors ()
  "Asking for a slice of a nonexistent buffer raises an error."
  :tags '(:fast)
  (should-error
   (edmcp--tools-buffer-substring
    '(:buffer "edmcp-no-such-buffer-substring"))))

(ert-deftest emacs-devtools-mcp-tests/buffer-substring-invalid-range-errors ()
  "Inverted range (start > end) raises a clear error."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-substring-bad-range" t)
    (insert "abcdef")
    (should-error
     (edmcp--tools-buffer-substring
      '(:buffer "edmcp-substring-bad-range" :start 5 :end 2)))))

(ert-deftest emacs-devtools-mcp-tests/buffer-substring-error-reports-raw-bounds ()
  "Range errors carry the raw client inputs, not silently-clamped values.
Pre-fix, an out-of-range start was clamped to `point-max' before
the inversion check fired, so a request like start=10000, end=9
on a small buffer reported `start NNN > end 9' where NNN was
the buffer's clamped point-max -- confusing for the agent who
sent 10000."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-substring-raw-bounds" t)
    (insert "abcdef")
    (let ((err (should-error
                (edmcp--tools-buffer-substring
                 '(:buffer "edmcp-substring-raw-bounds"
                   :start 10000 :end 9)))))
      (should (string-match-p "10000" (cadr err)))
      (should (string-match-p "\\b9\\b" (cadr err))))))

(ert-deftest emacs-devtools-mcp-tests/buffer-substring-drops-text-properties ()
  "Returned text is a plain string regardless of source buffer properties.
The JSON wire has no carrier for text properties, so claiming to
preserve them would be a lie; we drop them server-side."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-substring-props" t)
    (insert (propertize "hi" 'face 'bold))
    (let* ((res (edmcp--tools-buffer-substring
                 '(:buffer "edmcp-substring-props"
                   :start 1 :end 3)))
           (text (plist-get res :text)))
      (should (equal "hi" text))
      (should-not (get-text-property 0 'face text)))))

(ert-deftest emacs-devtools-mcp-tests/buffer-substring-zero-width-slice ()
  "An equal start/end pair returns empty text without erroring.
The bounds-check fires only on `start > end'; an empty range is a
valid request (e.g.\\ probing for a buffer's existence at a known
location) and must succeed with `text=\"\"' and no truncation."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-substring-zero" t)
    (insert "abcdef")
    (let ((res (edmcp--tools-buffer-substring
                '(:buffer "edmcp-substring-zero"
                  :start 3 :end 3))))
      (should (equal "" (plist-get res :text)))
      (should (eq :json-false (plist-get res :truncated))))))

(ert-deftest emacs-devtools-mcp-tests/buffer-substring-respects-multibyte-boundary ()
  "`max_bytes' never mid-cuts a multibyte UTF-8 codepoint.
A 4-byte emoji with `max_bytes=2' yields empty text and
`truncated:t', not half a codepoint -- otherwise the returned
string would fail to decode and any client that doesn't
defensively re-validate could corrupt downstream rendering.

Pins the contract on a `max_bytes' that is *too small for any
character*: the call returns successfully with no progress, and
the client's `next_offset' equals its `start'.  That stable
sentinel is what callers detect to bump the cap rather than
spinning."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-substring-mb" t)
    (insert "👍AB")
    (let ((res (edmcp--tools-buffer-substring
                `(:buffer "edmcp-substring-mb"
                  :start ,(point-min)
                  :end ,(point-max)
                  :max_bytes 2))))
      (should (eq t (plist-get res :truncated)))
      (should (equal "" (plist-get res :text)))
      (should (= (point-min) (plist-get res :next_offset))))
    ;; With max_bytes=4 the emoji fits exactly, but the trailing
    ;; "AB" must not -- and the truncation marker advances to the
    ;; character after the emoji.
    (let ((res (edmcp--tools-buffer-substring
                `(:buffer "edmcp-substring-mb"
                  :start ,(point-min)
                  :end ,(point-max)
                  :max_bytes 4))))
      (should (eq t (plist-get res :truncated)))
      (should (equal "👍" (plist-get res :text)))
      (should (= (1+ (point-min)) (plist-get res :next_offset))))))


(ert-deftest emacs-devtools-mcp-tests/list-messages-returns-redacted-tail ()
  "Recent *Messages* entries surface, with redacted lines stripped."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (let ((message-log-max 4096))
      (message "edmcp-list-messages-keep")
      (message "auth-source-edmcp-list-messages-drop %s" "secret"))
    (let* ((res (edmcp--tools-list-messages '(:n 50)))
           (entries (append (plist-get res :messages) nil))
           (joined (mapconcat #'identity entries "\n")))
      (should (string-match-p "edmcp-list-messages-keep" joined))
      (should-not (string-match-p "auth-source-edmcp-list-messages-drop"
                                  joined)))))

(ert-deftest emacs-devtools-mcp-tests/list-messages-rejects-non-positive-n ()
  "`list-messages' with `n <= 0' raises rather than silently returning `[]'.
Pre-fix, `n=0' and `n=-1' both flowed through `(last lines 0)'
and produced an empty result -- the agent saw no messages and
had no signal that the call had been malformed."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (let ((message-log-max 4096))
      (message "edmcp-list-messages-n0-keep"))
    (should-error (edmcp--tools-list-messages '(:n 0)))
    (should-error (edmcp--tools-list-messages '(:n -1)))
    ;; nil n is still accepted (defaults to page size).
    (should (edmcp--tools-list-messages '()))))

(ert-deftest emacs-devtools-mcp-tests/list-messages-rejects-bad-n-with-cursor ()
  "Non-positive `n' is rejected even when a `cursor' is also supplied.
The cursor path skips the spawn-call (and thus the `messages-tail'
n-validation), but a malformed `n' is a caller bug regardless --
silently letting the cursor win would mask it.  Up-front
validation in the handler catches the case."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (should-error
     (edmcp--tools-list-messages '(:n 0 :cursor "any-token")))
    (should-error
     (edmcp--tools-list-messages '(:n -5 :cursor "any-token")))))

(ert-deftest emacs-devtools-mcp-tests/list-warnings-returns-empty-when-no-buffer ()
  "If *Warnings* doesn't exist, the result is an empty array."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (when (get-buffer "*Warnings*") (kill-buffer "*Warnings*"))
    (let ((res (edmcp--tools-list-warnings '())))
      (should (vectorp (plist-get res :warnings)))
      (should (= 0 (length (plist-get res :warnings)))))))

(ert-deftest emacs-devtools-mcp-tests/list-warnings-paginates ()
  "Warnings exceeding the page size yield a `next_cursor' for the rest."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (let ((emacs-devtools-mcp-buffer-list-page-size 2))
      ;; Build a fake *Warnings* buffer with 5 paragraphs.
      (with-current-buffer (get-buffer-create "*Warnings*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "alpha\n\nbeta\n\ngamma\n\ndelta\n\nepsilon\n")))
      (unwind-protect
          (let* ((first (edmcp--tools-list-warnings '()))
                 (cur (plist-get first :next_cursor)))
            (should (= 2 (length (plist-get first :warnings))))
            (should (stringp cur))
            (let* ((second (edmcp--tools-list-warnings `(:cursor ,cur))))
              (should (= 2 (length (plist-get second :warnings))))
              (should (stringp (plist-get second :next_cursor)))))
        (kill-buffer "*Warnings*")))))

(ert-deftest emacs-devtools-mcp-tests/list-warnings-redacts-paragraphs ()
  "*Warnings* paragraphs flow through `emacs-devtools-mcp-redact'.
Pre-fix, `--warnings-list' returned the raw split paragraphs --
which meant an `auth-source-' / `epg-' / `tramp-' line dropped
into *Warnings* (e.g.\\ by a credential lookup probe) would
escape the redaction layer that gates `list-messages',
backtraces, and trace output.  Pinned alongside its sibling
`list-messages-returns-redacted-tail'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (with-current-buffer (get-buffer-create "*Warnings*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "harmless first warning\n\n"
                "auth-source-search failed: secret=SHHH\n\n"
                "epg-decrypt-string panic: hunter2\n\n"
                "another harmless paragraph\n")))
    (unwind-protect
        (let* ((res (edmcp--tools-list-warnings '()))
               (paras (append (plist-get res :warnings) nil))
               (joined (mapconcat #'identity paras "\n")))
          (should-not (string-match-p "auth-source-search" joined))
          (should-not (string-match-p "epg-decrypt-string" joined))
          (should-not (string-match-p "SHHH" joined))
          (should-not (string-match-p "hunter2" joined))
          (should (string-match-p "harmless first warning" joined))
          (should (string-match-p "another harmless paragraph" joined)))
      (kill-buffer "*Warnings*"))))

(ert-deftest emacs-devtools-mcp-tests/ert-run-summarizes ()
  "`ert-run' against a known passing selector returns a clean summary."
  :tags '(:fast)
  ;; Use an interned symbol so the selector resolves through `intern',
  ;; then unintern after to keep ERT's registry tidy.
  (let* ((name (format "edmcp-ert-fixture-pass-%d" (random 100000)))
         (sym (intern name)))
    (eval `(ert-deftest ,sym () (should t)) t)
    (unwind-protect
        (let ((res (edmcp--tools-ert-run `(:selector ,name))))
          (should (= 1 (plist-get res :total)))
          (should (= 1 (plist-get res :passed)))
          (should (= 0 (plist-get res :failed)))
          (should (eq t (plist-get res :ok))))
      (unintern sym nil))))

(ert-deftest emacs-devtools-mcp-tests/ert-run-emits-failures-vector-on-success ()
  "On a clean pass the `:failures' field is `[]', not `nil' or `:null'.
A nil here would serialize as JSON `null' and clients would have to
guard `length' calls with a type check.  A list-of-zero would
serialize as a JSON object.  Both are wire shapes the agent has
already learned not to expect.  The contract is `[]' --
empty JSON array -- and we pin it here."
  :tags '(:fast)
  (let* ((name (format "edmcp-ert-fixture-zero-fail-%d" (random 100000)))
         (sym (intern name)))
    (eval `(ert-deftest ,sym () (should t)) t)
    (unwind-protect
        (let* ((res (edmcp--tools-ert-run `(:selector ,name)))
               (failures (plist-get res :failures)))
          (should (vectorp failures))
          (should (= 0 (length failures)))
          ;; Wire round-trip: the field encodes as a JSON array `[]'.
          (let* ((json (json-serialize (list :failures failures)))
                 (parsed (json-parse-string json :object-type 'plist)))
            (should (vectorp (plist-get parsed :failures)))
            (should (= 0 (length (plist-get parsed :failures))))))
      (unintern sym nil))))

(ert-deftest emacs-devtools-mcp-tests/ert-run-reports-failure ()
  "A failing test produces `failed: 1', `ok: :json-false', and `:failures' detail.
The `:failures' vector carries `(:name :message)' entries so the
caller does not have to grep stderr to learn which test failed and
why."
  :tags '(:fast)
  (let* ((name (format "edmcp-ert-fixture-fail-%d" (random 100000)))
         (sym (intern name)))
    (eval `(ert-deftest ,sym () (should (= 1 99))) t)
    (unwind-protect
        (let* ((res (edmcp--tools-ert-run `(:selector ,name)))
               (failures (plist-get res :failures)))
          (should (= 1 (plist-get res :total)))
          (should (= 0 (plist-get res :passed)))
          (should (= 1 (plist-get res :failed)))
          (should (eq :json-false (plist-get res :ok)))
          (should (vectorp failures))
          (should (= 1 (length failures)))
          (should (equal name (plist-get (aref failures 0) :name)))
          (should (stringp (plist-get (aref failures 0) :message)))
          (should (> (length (plist-get (aref failures 0) :message)) 0)))
      (unintern sym nil))))

(ert-deftest emacs-devtools-mcp-tests/ert-run-rejects-unknown-selector ()
  "Selectors that do not resolve to a known test raise an error.
The reader successfully turns the string into a symbol, but
`ert-select-tests' raises when no matching test exists."
  :tags '(:fast)
  (should-error
   (edmcp--tools-ert-run
    '(:selector "edmcp-no-such-ert-test-anywhere-42"))))

(ert-deftest emacs-devtools-mcp-tests/ert-run-accepts-tag-selector ()
  "A `(tag :tagname)' selector runs every loaded test with that tag.
Regression: the previous handler `intern-soft'-ed the selector and
rejected anything but a symbol, so callers could not run a tag set
through `ert_run' even though ERT itself supports it."
  :tags '(:fast)
  (let* ((tag (intern (format "edmcp-tag-%d" (random 100000))))
         (n1 (format "edmcp-ert-tagged-pass-%d" (random 100000)))
         (n2 (format "edmcp-ert-tagged-pass-%d" (random 100000)))
         (s1 (intern n1))
         (s2 (intern n2)))
    (eval `(ert-deftest ,s1 () :tags '(,tag) (should t)) t)
    (eval `(ert-deftest ,s2 () :tags '(,tag) (should t)) t)
    (unwind-protect
        (let* ((sel (format "(tag %s)" tag))
               (res (edmcp--tools-ert-run `(:selector ,sel))))
          (should (= 2 (plist-get res :total)))
          (should (= 2 (plist-get res :passed)))
          (should (eq t (plist-get res :ok))))
      (unintern s1 nil)
      (unintern s2 nil))))

(ert-deftest emacs-devtools-mcp-tests/ert-run-accepts-regexp-selector ()
  "A double-quoted string selector is treated by ERT as a name regexp.
The wire string is read with the Lisp reader, so `\"foo\"' parses
to the Lisp string `foo' which `ert-select-tests' interprets as a
regexp matched against test names."
  :tags '(:fast)
  (let* ((tag (format "edmcp-regex-%d" (random 100000)))
         (n1 (format "%s-one" tag))
         (n2 (format "%s-two" tag))
         (n3 (format "edmcp-other-%d" (random 100000)))
         (s1 (intern n1))
         (s2 (intern n2))
         (s3 (intern n3)))
    (eval `(ert-deftest ,s1 () (should t)) t)
    (eval `(ert-deftest ,s2 () (should t)) t)
    (eval `(ert-deftest ,s3 () (should t)) t)
    (unwind-protect
        (let* ((sel (format "%S" (concat "\\`" (regexp-quote tag))))
               (res (edmcp--tools-ert-run `(:selector ,sel))))
          (should (= 2 (plist-get res :total)))
          (should (= 2 (plist-get res :passed))))
      (unintern s1 nil) (unintern s2 nil) (unintern s3 nil))))

(ert-deftest emacs-devtools-mcp-tests/ert-run-rejects-trailing-junk ()
  "Trailing characters after the first sexp cause a structured error.
Otherwise `read-from-string' would silently discard the tail and
the agent would be confused why `(or A B) garbage' selected only A."
  :tags '(:fast)
  (let ((err (should-error
              (edmcp--tools-ert-run
               '(:selector "(or foo bar) extra-junk")))))
    (should (string-match-p "Trailing characters" (cadr err)))))

(ert-deftest emacs-devtools-mcp-tests/describe-hooks-without-arg-lists-symbols ()
  "Bare `describe-hooks' returns a JSON-shaped plist, not a raw list.

Regression: the no-arg branch previously returned a flat list of
strings, which fell through `edmcp--server-wrap-content' to
`jsonrpc--json-encode' and crashed with a non-keyword-key error.
The handler now returns `(:hooks #(...))', and the `tools/call'
encode path is exercised end-to-end here."
  :tags '(:fast)
  (let* ((res (edmcp--tools-describe-hooks '()))
         (hooks (plist-get res :hooks)))
    (should (vectorp hooks))
    (should (seq-contains-p hooks "kill-emacs-hook"))
    ;; The whole envelope must encode without error.  This is the
    ;; regression check: previously the encode crashed.
    (should (stringp (jsonrpc--json-encode
                      (edmcp--server-wrap-content res))))))

(ert-deftest emacs-devtools-mcp-tests/describe-hooks-with-name-returns-functions ()
  "When HOOK is supplied, return its current contents as a vector.
The `:functions' value must be a vector so `json-serialize' emits
a JSON array; a plain list would be encoded as an alist/object."
  :tags '(:fast)
  (let* ((sym-name (format "edmcp-hook-fixture-%d" (random 100000)))
         (sym (intern sym-name)))
    (set sym '(some-fn another-fn))
    (unwind-protect
        (let* ((res (edmcp--tools-describe-hooks `(:hook ,sym-name)))
               (fns (plist-get res :functions)))
          (should (equal sym-name (plist-get res :name)))
          (should (vectorp fns))
          (should (seq-contains-p fns "some-fn"))
          (should (stringp (jsonrpc--json-encode
                            (edmcp--server-wrap-content res)))))
      (makunbound sym)
      (unintern sym nil))))

(ert-deftest emacs-devtools-mcp-tests/describe-hooks-unbound-hook-errors ()
  "An unbound hook name raises a clear error."
  :tags '(:fast)
  (should-error
   (edmcp--tools-describe-hooks
    '(:hook "edmcp-no-such-hook-symbol-anywhere"))))

;;;; ___Output cap___

(ert-deftest emacs-devtools-mcp-tests/payload-cap-too-large-becomes-error ()
  "A handler whose result exceeds the cap is replaced by `payload_too_large'."
  :tags '(:fast)
  (let* ((emacs-devtools-mcp--tool-registry (make-hash-table :test 'equal))
         (emacs-devtools-mcp-max-response-bytes 64))
    (eval '(emacs-devtools-mcp-deftool huge
               "Returns a giant string."
             :cost :fast
             :read-only t
             :handler (lambda (_p) (make-string 1024 ?x)))
          t)
    (let* ((envelope (edmcp--server-tools-call
                      nil '(:name "huge" :arguments nil))))
      (should (eq t (plist-get envelope :isError)))
      (should (string-match-p "payload_too_large"
                              (plist-get (aref (plist-get envelope :content) 0)
                                         :text))))))

(ert-deftest emacs-devtools-mcp-tests/payload-cap-under-budget-passes ()
  "When the response is under the cap, the handler's content is preserved."
  :tags '(:fast)
  (let* ((emacs-devtools-mcp--tool-registry (make-hash-table :test 'equal))
         (emacs-devtools-mcp-max-response-bytes (* 64 1024)))
    (eval '(emacs-devtools-mcp-deftool small
               "Tiny string."
             :cost :fast
             :read-only t
             :handler (lambda (_p) "ok"))
          t)
    (let ((envelope (edmcp--server-tools-call
                     nil '(:name "small" :arguments nil))))
      (should (eq :json-false (plist-get envelope :isError)))
      (should (equal "ok"
                     (plist-get (aref (plist-get envelope :content) 0)
                                :text))))))

(ert-deftest emacs-devtools-mcp-tests/payload-cap-image-detected ()
  "An envelope carrying an `image' content block is detected."
  :tags '(:fast)
  (let ((with-image (list :content
                          (vector (list :type "text" :text "ok")
                                  (list :type "image"
                                        :data "Zm9v"
                                        :mimeType "image/png"))
                          :isError :json-false))
        (text-only (list :content
                         (vector (list :type "text" :text "ok"))
                         :isError :json-false)))
    (should (edmcp--server-envelope-has-image-p with-image))
    (should-not (edmcp--server-envelope-has-image-p text-only))))

(ert-deftest emacs-devtools-mcp-tests/payload-cap-image-uses-larger-cap ()
  "An image envelope is sized against `max-image-response-bytes'.

Regression: when both caps were the same knob (256 KiB default),
a default-resolution screenshot's base64 always blew past the cap
and `screenshot_frame' returned `payload_too_large' even on a
working system.  The image cap now defaults to 8 MiB and is the
one applied when an image block is present, so a 1 MiB screenshot
passes through unchanged."
  :tags '(:fast)
  (let* ((emacs-devtools-mcp--tool-registry (make-hash-table :test 'equal))
         (emacs-devtools-mcp-max-response-bytes 64)
         (emacs-devtools-mcp-max-image-response-bytes (* 1 1024 1024))
         ;; A ~4 KiB base64 string -- well over the 64-byte text cap, but
         ;; well under the 1 MiB image cap.
         (b64 (base64-encode-string (make-string 3000 ?x) t)))
    (eval `(emacs-devtools-mcp-deftool fake-shot
               "Returns a fake screenshot envelope."
             :cost :fast
             :read-only t
             :handler (lambda (_p)
                        (list :content
                              (vector (list :type "image"
                                            :data ,b64
                                            :mimeType "image/png")))))
          t)
    (let ((envelope (edmcp--server-tools-call
                     nil '(:name "fake_shot" :arguments nil))))
      (should (eq :json-false (plist-get envelope :isError)))
      (should (equal "image"
                     (plist-get (aref (plist-get envelope :content) 0)
                                :type))))))

(ert-deftest emacs-devtools-mcp-tests/payload-cap-image-still-bounded ()
  "Even the image cap is enforced; oversize image responses fail."
  :tags '(:fast)
  (let* ((emacs-devtools-mcp--tool-registry (make-hash-table :test 'equal))
         (emacs-devtools-mcp-max-response-bytes 64)
         (emacs-devtools-mcp-max-image-response-bytes 256)
         (b64 (base64-encode-string (make-string 4096 ?x) t)))
    (eval `(emacs-devtools-mcp-deftool fake-shot-huge
               "Returns a too-big screenshot envelope."
             :cost :fast
             :read-only t
             :handler (lambda (_p)
                        (list :content
                              (vector (list :type "image"
                                            :data ,b64
                                            :mimeType "image/png")))))
          t)
    (let ((envelope (edmcp--server-tools-call
                     nil '(:name "fake_shot_huge" :arguments nil))))
      (should (eq t (plist-get envelope :isError)))
      (let ((text (plist-get (aref (plist-get envelope :content) 0) :text)))
        (should (string-match-p "payload_too_large" text))
        ;; The error mentions the image cap (256), not the text cap (64).
        (should (string-match-p "256" text))))))

;;;; ___Keys___

(ert-deftest emacs-devtools-mcp-tests/keys-resolve-keymap-global ()
  "A nil name resolves to the current global map."
  :tags '(:fast)
  (should (eq (current-global-map)
              (emacs-devtools-mcp-tools-keys--resolve-keymap nil))))

(ert-deftest emacs-devtools-mcp-tests/keys-resolve-keymap-direct-variable ()
  "A variable bound to a keymap resolves directly."
  :tags '(:fast)
  (should (keymapp
           (emacs-devtools-mcp-tools-keys--resolve-keymap
            "emacs-lisp-mode-map"))))

(ert-deftest emacs-devtools-mcp-tests/keys-resolve-keymap-mode-fallback ()
  "Passing a `-mode' name falls back to `<NAME>-map'."
  :tags '(:fast)
  (should (keymapp
           (emacs-devtools-mcp-tools-keys--resolve-keymap "emacs-lisp-mode"))))

(ert-deftest emacs-devtools-mcp-tests/keys-resolve-keymap-unknown-errors ()
  "Resolving a symbol whose value is not a keymap signals."
  :tags '(:fast)
  (should-error
   (emacs-devtools-mcp-tools-keys--resolve-keymap "edmcp-not-a-keymap-symbol")))

(ert-deftest emacs-devtools-mcp-tests/where-is-finds-find-file ()
  "`find-file' has a binding under the global map."
  :tags '(:fast)
  (let* ((res (edmcp--tools-where-is '(:command "find-file")))
         (binds (append (plist-get res :bindings) nil)))
    (should (cl-find-if (lambda (s) (string-match-p "C-x C-f" s)) binds))))

(ert-deftest emacs-devtools-mcp-tests/where-is-unknown-command-errors ()
  "An unknown command name signals."
  :tags '(:fast)
  (should-error
   (edmcp--tools-where-is '(:command "edmcp-no-such-command-anywhere"))))

(ert-deftest emacs-devtools-mcp-tests/where-is-empty-when-unbound ()
  "A bound function with no key gets an empty bindings array."
  :tags '(:fast)
  (let ((sym (intern (format "edmcp-unbound-fn-%d" (random 100000)))))
    (defalias sym (lambda () (interactive) nil))
    (unwind-protect
        (let ((res (edmcp--tools-where-is `(:command ,(symbol-name sym)))))
          (should (vectorp (plist-get res :bindings)))
          (should (= 0 (length (plist-get res :bindings)))))
      (fmakunbound sym)
      (unintern sym nil))))

(ert-deftest emacs-devtools-mcp-tests/where-is-filters-menu-bar-pseudo-bindings ()
  "Menu-bar / tool-bar / remap entries don't appear alongside real keys.
`where-is-internal' returns sequences like `[menu-bar file
new-file]' or `[remap forward-char]' for commands reachable
through menus; surfacing those next to actual key sequences was
noise for agents trying to discover keystrokes."
  :tags '(:fast)
  (let* ((sym (intern (format "edmcp-where-is-menu-fn-%d" (random 100000))))
         (menu-map (make-sparse-keymap))
         (real-map (make-sparse-keymap))
         (top (make-sparse-keymap))
         (map-sym (intern (format "edmcp-where-is-map-%d" (random 100000)))))
    (defalias sym (lambda () (interactive) nil))
    (define-key menu-map [my-entry]
                (cons "Do thing" sym))
    (define-key real-map (kbd "a") sym)
    (define-key top [menu-bar my-menu] (cons "My" menu-map))
    (set-keymap-parent top real-map)
    (set map-sym top)
    (unwind-protect
        (let* ((res (edmcp--tools-where-is
                     (list :command (symbol-name sym)
                           :keymap (symbol-name map-sym))))
               (binds (append (plist-get res :bindings) nil)))
          ;; The real `a' binding is present.
          (should (member "a" binds))
          ;; Menu-bar pseudo-bindings are filtered out.
          (should-not (cl-some (lambda (k) (string-match-p "menu-bar" k))
                               binds)))
      (makunbound map-sym)
      (unintern map-sym nil)
      (fmakunbound sym)
      (unintern sym nil))))

(ert-deftest emacs-devtools-mcp-tests/where-is-filters-remap-bindings ()
  "`[remap COMMAND]' entries are filtered out of `where-is' results."
  :tags '(:fast)
  (let* ((sym (intern (format "edmcp-where-is-remap-%d" (random 100000))))
         (map (make-sparse-keymap))
         (map-sym (intern (format "edmcp-where-is-remap-map-%d"
                                  (random 100000)))))
    (defalias sym (lambda () (interactive) nil))
    (define-key map (kbd "g") sym)
    (define-key map [remap forward-char] sym)
    (set map-sym map)
    (unwind-protect
        (let* ((res (edmcp--tools-where-is
                     (list :command (symbol-name sym)
                           :keymap (symbol-name map-sym))))
               (binds (append (plist-get res :bindings) nil)))
          (should (member "g" binds))
          (should-not (cl-some (lambda (k) (string-match-p "remap" k))
                               binds)))
      (makunbound map-sym)
      (unintern map-sym nil)
      (fmakunbound sym)
      (unintern sym nil))))

(ert-deftest emacs-devtools-mcp-tests/lookup-key-returns-binding ()
  "`lookup-key' on the global map yields the symbol name as a string."
  :tags '(:fast)
  (let ((res (edmcp--tools-lookup-key '(:keys "C-x C-f"))))
    (should (equal "find-file" (plist-get res :binding)))))

(ert-deftest emacs-devtools-mcp-tests/lookup-key-undefined ()
  "An unbound key sequence reports `\"undefined\"'."
  :tags '(:fast)
  (let* ((map (make-sparse-keymap))
         (map-sym (intern (format "edmcp-empty-keymap-%d" (random 100000)))))
    ;; Bind something unrelated so the lookup truly returns nil rather
    ;; than 0 (zero-events-consumed on a fully empty map).
    (define-key map (kbd "a") 'forward-char)
    (set map-sym map)
    (unwind-protect
        (let ((res (edmcp--tools-lookup-key
                    `(:keys "C-z" :keymap ,(symbol-name map-sym)))))
          (should (equal "undefined" (plist-get res :binding))))
      (makunbound map-sym)
      (unintern map-sym nil))))

(ert-deftest emacs-devtools-mcp-tests/lookup-key-prefix-returns-integer ()
  "A prefix key sequence yields a `:prefix' integer (per `lookup-key')."
  :tags '(:fast)
  (let* ((parent (make-sparse-keymap))
         (child (make-sparse-keymap))
         (map-sym (intern (format "edmcp-prefix-keymap-%d" (random 100000)))))
    (define-key parent (kbd "C-c") child)
    (define-key child (kbd "a") 'ignore)
    (set map-sym parent)
    (unwind-protect
        ;; "C-c a x" -- "C-c a" binds to ignore, x trails => integer
        (let ((res (edmcp--tools-lookup-key
                    `(:keys "C-c a x"
                      :keymap ,(symbol-name map-sym)))))
          (should (integerp (plist-get res :prefix))))
      (makunbound map-sym)
      (unintern map-sym nil))))

(ert-deftest emacs-devtools-mcp-tests/describe-keymap-flattens ()
  "Bindings under a defined keymap appear in the flattened result."
  :tags '(:fast)
  (let* ((m (make-sparse-keymap))
         (sub (make-sparse-keymap))
         (sym (intern (format "edmcp-desc-keymap-%d" (random 100000)))))
    (define-key m (kbd "a") 'forward-char)
    (define-key m (kbd "C-c") sub)
    (define-key sub (kbd "x") 'backward-char)
    (set sym m)
    (unwind-protect
        (let* ((res (edmcp--tools-describe-keymap
                     `(:keymap ,(symbol-name sym))))
               (binds (append (plist-get res :bindings) nil)))
          (should (cl-find-if (lambda (e)
                                (and (equal "a" (plist-get e :keys))
                                     (equal "forward-char"
                                            (plist-get e :binding))))
                              binds))
          (should (cl-find-if (lambda (e)
                                (and (equal "C-c x" (plist-get e :keys))
                                     (equal "backward-char"
                                            (plist-get e :binding))))
                              binds)))
      (makunbound sym)
      (unintern sym nil))))

(ert-deftest emacs-devtools-mcp-tests/describe-keymap-prefix-narrows ()
  "PREFIX filters the flattened bindings to those starting with it."
  :tags '(:fast)
  (let* ((m (make-sparse-keymap))
         (sub (make-sparse-keymap))
         (sym (intern (format "edmcp-desc-prefix-%d" (random 100000)))))
    (define-key m (kbd "a") 'forward-char)
    (define-key m (kbd "C-c") sub)
    (define-key sub (kbd "x") 'backward-char)
    (set sym m)
    (unwind-protect
        (let* ((res (edmcp--tools-describe-keymap
                     `(:keymap ,(symbol-name sym) :prefix "C-c")))
               (binds (append (plist-get res :bindings) nil)))
          (should (= 1 (length binds)))
          (should (equal "C-c x" (plist-get (car binds) :keys))))
      (makunbound sym)
      (unintern sym nil))))

(ert-deftest emacs-devtools-mcp-tests/describe-keymap-paginates ()
  "A wide keymap paginates with a `next_cursor' on the first page."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (let* ((emacs-devtools-mcp-keys-page-size 3)
           (m (make-sparse-keymap))
           (sym (intern (format "edmcp-desc-page-%d" (random 100000)))))
      (dotimes (i 7)
        (define-key m (vector (+ ?a i)) 'forward-char))
      (set sym m)
      (unwind-protect
          (let* ((first (edmcp--tools-describe-keymap
                         `(:keymap ,(symbol-name sym))))
                 (cur (plist-get first :next_cursor)))
            (should (= 3 (length (plist-get first :bindings))))
            (should (stringp cur))
            (let ((second (edmcp--tools-describe-keymap
                           `(:keymap ,(symbol-name sym) :cursor ,cur))))
              (should (= 3 (length (plist-get second :bindings))))
              (should (stringp (plist-get second :next_cursor)))))
        (makunbound sym)
        (unintern sym nil)))))

(ert-deftest emacs-devtools-mcp-tests/describe-keymap-empty-map-returns-empty-array ()
  "A bound but empty keymap returns `:bindings []' without erroring.
Distinguishes \"valid keymap, no bindings\" from \"unknown keymap\"
(which signals).  The wire shape is a JSON array, not nil; clients
can `length' it without a type guard."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (let* ((sym (intern (format "edmcp-empty-keymap-%d" (random 100000)))))
      (set sym (make-sparse-keymap))
      (unwind-protect
          (let* ((res (edmcp--tools-describe-keymap
                       `(:keymap ,(symbol-name sym))))
                 (bindings (plist-get res :bindings)))
            (should (vectorp bindings))
            (should (= 0 (length bindings)))
            (should-not (plist-get res :next_cursor)))
        (makunbound sym)
        (unintern sym nil)))))

(ert-deftest emacs-devtools-mcp-tests/describe-keymap-unmatched-prefix-returns-empty ()
  "A `prefix' that matches no binding returns an empty page, not an error.
The prefix filter is a *narrower*, not a precondition: an empty
result is the natural answer to \"what bindings start with X\" when
X is not a prefix of any binding.  Pinning this contract guards
against a future regression that would error on the empty-narrow
case."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-fresh-cursors
    (let* ((sym (intern (format "edmcp-prefix-miss-%d" (random 100000))))
           (m (make-sparse-keymap)))
      (define-key m (kbd "C-c a") 'forward-char)
      (define-key m (kbd "C-c b") 'backward-char)
      (set sym m)
      (unwind-protect
          (let* ((res (edmcp--tools-describe-keymap
                       `(:keymap ,(symbol-name sym)
                         :prefix "C-z"))))
            (should (vectorp (plist-get res :bindings)))
            (should (= 0 (length (plist-get res :bindings)))))
        (makunbound sym)
        (unintern sym nil)))))

(ert-deftest emacs-devtools-mcp-tests/simulate-keys-moves-point ()
  "Cursor-motion commands run by `simulate-keys' update point."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-sim-motion" t)
    (insert "hello world")
    (goto-char (point-min))
    (let ((res (edmcp--tools-simulate-keys
                '(:keys "C-f C-f C-f"
                  :buffer "edmcp-sim-motion"))))
      (should (equal "edmcp-sim-motion" (plist-get res :buffer)))
      (should (= 11 (plist-get res :buffer_size)))
      (should (= 4 (plist-get res :point)))
      (should (string-match-p "hello world" (plist-get res :text))))))

(ert-deftest emacs-devtools-mcp-tests/simulate-keys-missing-buffer-errors ()
  "A non-existent buffer name signals."
  :tags '(:fast)
  (should-error
   (edmcp--tools-simulate-keys
    '(:keys "x" :buffer "edmcp-no-such-buffer-sim"))))

(ert-deftest emacs-devtools-mcp-tests/simulate-keys-redacts-messages ()
  "*Messages* lines containing redacted prefixes are stripped."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-sim-redact" t)
    (let ((sym (intern (format "edmcp-msg-cmd-%d" (random 100000))))
          (map (make-sparse-keymap)))
      (defalias sym
        (lambda ()
          (interactive)
          (message "auth-source-edmcp-leak %s" "secret")
          (message "edmcp-keep-me")))
      (define-key map (kbd "C-c x") sym)
      (use-local-map map)
      (unwind-protect
          (let* ((res (edmcp--tools-simulate-keys
                       '(:keys "C-c x" :buffer "edmcp-sim-redact"))))
            (should (string-match-p "edmcp-keep-me"
                                    (plist-get res :messages)))
            (should-not (string-match-p "auth-source-edmcp-leak"
                                        (plist-get res :messages))))
        (fmakunbound sym)
        (unintern sym nil)))))

(ert-deftest emacs-devtools-mcp-tests/simulate-keys-isolates-undo ()
  "Undo state stays intact across simulation; content reflects the macro."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-sim-undo" t)
    (buffer-enable-undo)
    (insert "abc")
    (goto-char (point-min))
    (let ((before-undo buffer-undo-list)
          (before-len (length buffer-undo-list)))
      (edmcp--tools-simulate-keys
       '(:keys "C-f C-f" :buffer "edmcp-sim-undo"))
      ;; `buffer-undo-list' is `let'-bound to t for the duration, so
      ;; macro edits never touch it.  The list head AND length must
      ;; match the pre-call state.
      (should (eq before-undo buffer-undo-list))
      (should (= before-len (length buffer-undo-list)))
      ;; The macro itself ran -- point moved past the first two chars.
      (should (= 3 (point))))))

(ert-deftest emacs-devtools-mcp-tests/key-translation-trace-shape ()
  "The trace returns one entry per translation map plus the input."
  :tags '(:fast)
  (let ((res (edmcp--tools-key-translation-trace '(:keys "C-x C-f"))))
    (should (stringp (plist-get res :input)))
    (should (stringp (plist-get res :local_function_key_map)))
    (should (stringp (plist-get res :key_translation_map)))
    (should (stringp (plist-get res :function_key_map)))))

(ert-deftest emacs-devtools-mcp-tests/key-translation-trace-rt ()
  "The trace's `:input' round-trips through `kbd'/`key-description'."
  :tags '(:fast)
  (let ((res (edmcp--tools-key-translation-trace '(:keys "C-x"))))
    (should (equal "C-x" (plist-get res :input)))))

;;;; ___GUI___

(ert-deftest emacs-devtools-mcp-tests/contrast-black-on-white-is-21 ()
  "Black on white WCAG contrast is the maximum ratio of 21."
  :tags '(:fast)
  (let* ((res (edmcp--tools-color-contrast
               '(:foreground "#000000" :background "#ffffff")))
         (r (plist-get res :ratio)))
    (should (< (abs (- r 21.0)) 0.01))
    (should (eq (plist-get res :passes_aaa) t))
    (should (eq (plist-get res :passes_aa) t))))

(ert-deftest emacs-devtools-mcp-tests/contrast-identity-is-1 ()
  "Identical colors yield ratio 1.0 and fail every threshold."
  :tags '(:fast)
  (let* ((res (edmcp--tools-color-contrast
               '(:foreground "#888888" :background "#888888")))
         (r (plist-get res :ratio)))
    (should (< (abs (- r 1.0)) 0.001))
    (should (eq (plist-get res :passes_aa) :json-false))
    (should (eq (plist-get res :passes_aaa) :json-false))
    (should (eq (plist-get res :passes_aa_large) :json-false))))

(ert-deftest emacs-devtools-mcp-tests/contrast-symmetric ()
  "Swapping FG and BG yields the same ratio."
  :tags '(:fast)
  (let* ((a (edmcp--tools-color-contrast
             '(:foreground "#0044aa" :background "#ffeecc")))
         (b (edmcp--tools-color-contrast
             '(:foreground "#ffeecc" :background "#0044aa"))))
    (should (< (abs (- (plist-get a :ratio) (plist-get b :ratio)))
               0.0001))))

(ert-deftest emacs-devtools-mcp-tests/contrast-ratio-str-format ()
  "Formatted ratio string has exactly two decimal places."
  :tags '(:fast)
  (let ((res (edmcp--tools-color-contrast
              '(:foreground "#000000" :background "#ffffff"))))
    (should (string-match-p "\\`[0-9]+\\.[0-9][0-9]\\'"
                            (plist-get res :ratio_str)))))

(ert-deftest emacs-devtools-mcp-tests/contrast-aa-threshold ()
  "Ratio 4.5 sits exactly on the AA boundary; #767676 vs white is AA."
  :tags '(:fast)
  ;; #767676 vs white is ~4.54 -- a canonical AA-passing pair.
  (let ((res (edmcp--tools-color-contrast
              '(:foreground "#767676" :background "#ffffff"))))
    (should (eq (plist-get res :passes_aa) t))
    ;; Same pair fails AAA (needs >= 7.0).
    (should (eq (plist-get res :passes_aaa) :json-false))))

(ert-deftest emacs-devtools-mcp-tests/contrast-named-colors ()
  "Named colors resolve through `color-name-to-rgb'."
  :tags '(:fast)
  (let ((res (edmcp--tools-color-contrast
              '(:foreground "black" :background "white"))))
    (should (< (abs (- 21.0 (plist-get res :ratio))) 0.01))))

(ert-deftest emacs-devtools-mcp-tests/contrast-rejects-bad-color ()
  "Unparseable color spec raises a tool-execution error."
  :tags '(:fast)
  (should-error
   (edmcp--tools-color-contrast
    '(:foreground "not-a-color" :background "white"))))

(ert-deftest emacs-devtools-mcp-tests/contrast-rejects-oversize-color ()
  "Color specs over 128 chars are rejected before hitting `color-name-to-rgb'."
  :tags '(:fast)
  (let ((huge (make-string 200 ?a)))
    (should-error
     (edmcp--tools-color-contrast
      (list :foreground huge :background "white")))))

(ert-deftest emacs-devtools-mcp-tests/list-faces-rejects-bad-regex ()
  "Malformed FILTER regex raises a tool-execution error."
  :tags '(:fast)
  (should-error
   (edmcp--tools-list-faces '(:filter "[unclosed"))))

(ert-deftest emacs-devtools-mcp-tests/list-faces-rejects-oversize-filter ()
  "FILTER strings over 256 chars are rejected up-front."
  :tags '(:fast)
  (let ((huge (make-string 300 ?a)))
    (should-error
     (edmcp--tools-list-faces (list :filter huge)))))

(ert-deftest emacs-devtools-mcp-tests/face-at-default-buffer ()
  "Face at column 0 of an unfaced buffer is `default'."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-face-default" t)
    (insert "hello")
    (let ((res (edmcp--tools-face-at
                '(:buffer "edmcp-face-default" :line 1 :column 0))))
      (should (equal "default" (plist-get res :face)))
      (should (= 1 (plist-get res :position))))))

(ert-deftest emacs-devtools-mcp-tests/face-at-propertized-region ()
  "Face at a propertized character returns the applied face symbol."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-face-prop" t)
    (insert "abcdef")
    (put-text-property 3 5 'face 'font-lock-keyword-face)
    (let ((res (edmcp--tools-face-at
                '(:buffer "edmcp-face-prop" :line 1 :column 3))))
      (should (equal "font-lock-keyword-face" (plist-get res :face))))))

(ert-deftest emacs-devtools-mcp-tests/face-at-missing-buffer-errors ()
  "Unknown buffer raises a tool-execution error."
  :tags '(:fast)
  (should-error
   (edmcp--tools-face-at
    '(:buffer "edmcp-no-such-buffer-xyz" :line 1 :column 0))))

(ert-deftest emacs-devtools-mcp-tests/face-at-out-of-range-column ()
  "Column past the end of line raises a tool-execution error."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-face-oob" t)
    (insert "abc")
    (should-error
     (edmcp--tools-face-at
      '(:buffer "edmcp-face-oob" :line 1 :column 50)))))

(ert-deftest emacs-devtools-mcp-tests/face-at-out-of-range-line-rejected ()
  "Lines past end-of-buffer (or below 1) raise rather than clamping silently.
Pre-fix, `line=99999' on a small buffer dropped to point-max and
`line=0' silently moved backwards from point-min, so the agent
got back a face for whatever happened to be there -- with no way
to tell the call had used an out-of-range coordinate."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-face-line-oob" t)
    (insert "one\ntwo\nthree")
    ;; Past end of buffer.
    (should-error
     (edmcp--tools-face-at
      '(:buffer "edmcp-face-line-oob" :line 99999 :column 0)))
    ;; Zero / negative.
    (should-error
     (edmcp--tools-face-at
      '(:buffer "edmcp-face-line-oob" :line 0 :column 0)))
    (should-error
     (edmcp--tools-face-at
      '(:buffer "edmcp-face-line-oob" :line -1 :column 0)))))

(ert-deftest emacs-devtools-mcp-tests/face-at-negative-column-rejected ()
  "Negative column raises rather than clamping to bol."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-face-col-neg" t)
    (insert "abc")
    (should-error
     (edmcp--tools-face-at
      '(:buffer "edmcp-face-col-neg" :line 1 :column -1)))))

(ert-deftest emacs-devtools-mcp-tests/face-at-honors-narrowing ()
  "`face-at' counts lines through the *visible* region of a narrowed buffer.
`forward-line' from `(point-min)' both respect narrowing, so a
buffer with 10 underlying lines but narrowed to 3 visible lines
treats line 4 as out-of-range -- that's the contract the agent
needs (lines visible to the buffer is what they can address).
Pre-fix or post-regression, a silent clamp here would resolve the
agent's request to a face from the wrong line.

Also pin the success path inside the narrowed region so a future
change cannot \"fix\" the OOB error by accidentally widening."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-face-narrow" t)
    (dotimes (i 10) (insert (format "line%d\n" i)))
    ;; Narrow to the third line only (1-based: starts at char 13).
    (let* ((bol3 (save-excursion
                   (goto-char (point-min))
                   (forward-line 2)
                   (point)))
           (eol3 (save-excursion (goto-char bol3) (line-end-position))))
      (narrow-to-region bol3 eol3))
    ;; Inside the narrowed region: line 1 resolves.
    (let ((res (edmcp--tools-face-at
                '(:buffer "edmcp-face-narrow"
                  :line 1 :column 0))))
      (should (stringp (plist-get res :face))))
    ;; Beyond the narrowed region: error mentions the line count
    ;; that is *visible*, not the underlying buffer's 10 lines.
    (let* ((err (should-error
                 (edmcp--tools-face-at
                  '(:buffer "edmcp-face-narrow" :line 4 :column 0))))
           (msg (error-message-string err)))
      (should (string-match-p "past end of buffer" msg))
      ;; The narrowed region has exactly 1 line; the error message
      ;; carries that count, not "10".
      (should-not (string-match-p "10 lines" msg)))))

(ert-deftest emacs-devtools-mcp-tests/describe-face-default ()
  "`default' face has a name and an attribute alist."
  :tags '(:fast)
  (let ((res (edmcp--tools-describe-face '(:name "default"))))
    (should (equal "default" (plist-get res :name)))
    (should (listp (plist-get res :attributes)))))

(ert-deftest emacs-devtools-mcp-tests/describe-face-unknown-errors ()
  "Unknown face name raises a tool-execution error."
  :tags '(:fast)
  (should-error
   (edmcp--tools-describe-face '(:name "edmcp-no-such-face-xyz"))))

(ert-deftest emacs-devtools-mcp-tests/list-faces-includes-default ()
  "`default' appears in the unfiltered face list."
  :tags '(:fast)
  (let* ((res (edmcp--tools-list-faces '()))
         (faces (append (plist-get res :faces) nil)))
    (should (member "default" faces))))

(ert-deftest emacs-devtools-mcp-tests/list-faces-filter-narrows ()
  "Filter regex narrows results to matching face names."
  :tags '(:fast)
  (let* ((res (edmcp--tools-list-faces '(:filter "\\`mode-line")))
         (faces (append (plist-get res :faces) nil)))
    (should faces)
    (should (cl-every (lambda (f) (string-match-p "\\`mode-line" f))
                      faces))))

(ert-deftest emacs-devtools-mcp-tests/list-faces-paginates ()
  "Small page size emits a `next_cursor' that returns the rest."
  :tags '(:fast)
  (let* ((emacs-devtools-mcp-faces-page-size 3)
         (first (edmcp--tools-list-faces '()))
         (cursor (plist-get first :next_cursor)))
    (should (= 3 (length (plist-get first :faces))))
    (should cursor)
    (let ((second (edmcp--tools-list-faces (list :cursor cursor))))
      (should (vectorp (plist-get second :faces)))
      (should (> (length (plist-get second :faces)) 0)))))

(ert-deftest emacs-devtools-mcp-tests/list-faces-empty-filter-noop ()
  "Empty-string filter behaves like no filter at all."
  :tags '(:fast)
  (let* ((unfiltered (edmcp--tools-list-faces '()))
         (empty (edmcp--tools-list-faces '(:filter ""))))
    (should (= (length (plist-get unfiltered :faces))
               (length (plist-get empty :faces))))))

(ert-deftest emacs-devtools-mcp-tests/get-frame-tree-shape ()
  "Frame tree returns a vector with at least one frame entry."
  :tags '(:fast)
  (let* ((res (edmcp--tools-get-frame-tree '()))
         (frames (plist-get res :frames)))
    (should (vectorp frames))
    (should (>= (length frames) 1))
    (let ((first (aref frames 0)))
      (should (plist-member first :name))
      (should (plist-member first :pixel_width))
      (should (vectorp (plist-get first :windows))))))

(ert-deftest emacs-devtools-mcp-tests/get-frame-tree-missing-frame-errors ()
  "Asking for a non-existent frame name raises an error."
  :tags '(:fast)
  (should-error
   (edmcp--tools-get-frame-tree '(:frame "edmcp-no-such-frame-xyz"))))

(ert-deftest emacs-devtools-mcp-tests/screenshot-frame-batch-errors ()
  "In batch mode (no display), `screenshot-frame' returns an error."
  :tags '(:fast)
  (skip-unless noninteractive)
  (let ((emacs-devtools-mcp-tools-gui--host-backend nil))
    (should-error
     (edmcp--tools-screenshot-frame '()))))

(ert-deftest emacs-devtools-mcp-tests/screenshot-frame-no-meta-envelope ()
  "Screenshot result is the bare MCP image content block without `_meta'."
  :tags '(:fast)
  ;; Stub the screenshot helper so we can exercise the wrapping in
  ;; batch.  Verifies the envelope shape, not actual capture.
  (cl-letf (((symbol-function
              'emacs-devtools-mcp-tools-gui--screenshot)
             (lambda (_name)
               (list :width 800
                     :height 600
                     :mimeType "image/png"
                     :data "AAA="))))
    (let ((res (edmcp--tools-screenshot-frame '())))
      (should (vectorp (plist-get res :content)))
      (should (= 1 (length (plist-get res :content))))
      (should-not (plist-member res :_meta))
      (let ((blk (aref (plist-get res :content) 0)))
        (should (equal "image" (plist-get blk :type)))
        (should (equal "image/png" (plist-get blk :mimeType)))
        (should (equal "AAA=" (plist-get blk :data)))))))

(ert-deftest emacs-devtools-mcp-tests/parse-hex-three-digit ()
  "Three-digit hex `#abc' expands by replicating each nibble."
  :tags '(:fast)
  (let* ((rgb (emacs-devtools-mcp-tools-gui--parse-hex "#fff"))
         (rgb0 (emacs-devtools-mcp-tools-gui--parse-hex "#000")))
    (should (cl-every (lambda (x) (< (abs (- x 1.0)) 0.0001)) rgb))
    (should (cl-every (lambda (x) (= x 0.0)) rgb0))))

(ert-deftest emacs-devtools-mcp-tests/parse-hex-twelve-digit ()
  "Twelve-digit hex `#rrrrggggbbbb' parses each 16-bit channel."
  :tags '(:fast)
  (let ((rgb (emacs-devtools-mcp-tools-gui--parse-hex
              "#ffff00000000")))
    (should (< (abs (- 1.0 (nth 0 rgb))) 0.0001))
    (should (= 0.0 (nth 1 rgb)))
    (should (= 0.0 (nth 2 rgb)))))

(ert-deftest emacs-devtools-mcp-tests/parse-hex-rejects-bad-length ()
  "Hex strings of unsupported length yield nil."
  :tags '(:fast)
  (should-not (emacs-devtools-mcp-tools-gui--parse-hex "#ff"))
  (should-not (emacs-devtools-mcp-tools-gui--parse-hex "#fffff"))
  (should-not (emacs-devtools-mcp-tools-gui--parse-hex "abc")))

(ert-deftest emacs-devtools-mcp-tests/face-at-tab-line ()
  "Column counts characters, not visual columns -- tabs are one char each."
  :tags '(:fast)
  (with-temp-buffer
    (rename-buffer "edmcp-face-tab" t)
    (insert "\t\thi")
    ;; Buffer is four characters: TAB TAB h i.  Column 0..3 are
    ;; valid character offsets; column 4 sits at end-of-line; 5+
    ;; is out of range.
    (dotimes (col 4)
      (let ((res (edmcp--tools-face-at
                  (list :buffer "edmcp-face-tab" :line 1 :column col))))
        (should res)))
    (should-error
     (edmcp--tools-face-at
      '(:buffer "edmcp-face-tab" :line 1 :column 100)))))

(ert-deftest emacs-devtools-mcp-tests/describe-face-inherits ()
  "`describe-face' surfaces `:inherit' when present."
  :tags '(:fast)
  ;; `mode-line-emphasis' inherits from `bold' in stock Emacs.
  ;; Use an existing inheriting face if available; else skip.
  (let* ((sym 'mode-line-emphasis))
    (skip-unless (facep sym))
    (let* ((res (edmcp--tools-describe-face
                 (list :name (symbol-name sym))))
           (attrs (plist-get res :attributes)))
      (should (assq 'inherit attrs)))))

(ert-deftest emacs-devtools-mcp-tests/get-frame-tree-named-frame ()
  "Asking for an existing frame by name returns just that frame."
  :tags '(:fast)
  (let* ((this (frame-parameter (selected-frame) 'name))
         (res (edmcp--tools-get-frame-tree (list :frame this)))
         (frames (plist-get res :frames)))
    (should (= 1 (length frames)))
    (should (equal this (plist-get (aref frames 0) :name)))))

(ert-deftest emacs-devtools-mcp-tests/screenshot-frame-cap-rejects-oversize ()
  "When pixel area exceeds the cap the screenshot path errors out cleanly."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-tools-gui--host-backend 'x-export-frames)
        (emacs-devtools-mcp-screenshot-max-pixels (cons 1 1)))
    ;; Even though the backend probe was forced, the size check
    ;; runs before we'd ever reach `x-export-frames'.
    (should-error
     (edmcp--tools-screenshot-frame '()))))

(ert-deftest emacs-devtools-mcp-tests/screenshot-too-large-message-is-area-shaped ()
  "Oversize-frame error names pixel area, not WxH-vs-WxH.

Regression: the old message read `Frame too large: 1920x1080
exceeds cap 100x100', which compared two box dimensions even
though the actual check was `(* w h) > cap'.  A 200x10 frame
\(area 2000) compared favourably against the 100x100 cap on
either dimension, but the message implied otherwise.  The new
message reads `... = N pixels exceeds area cap M (= WxH; ...)' so
the cap and the comparison both surface as areas."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-tools-gui--host-backend 'x-export-frames)
        (emacs-devtools-mcp-screenshot-max-pixels (cons 10 10)))
    (let* ((err (should-error (edmcp--tools-screenshot-frame '())))
           (msg (error-message-string err)))
      (should (string-match-p "pixels" msg))
      (should (string-match-p "area cap" msg)))))

(ert-deftest emacs-devtools-mcp-tests/probe-host-backend-batch-is-unavailable ()
  "Backend probe in batch mode resolves to `unavailable'."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-tools-gui--host-backend nil))
    (should (eq 'unavailable
                (emacs-devtools-mcp-tools-gui--probe-host-backend)))))

(ert-deftest emacs-devtools-mcp-tests/probe-host-backend-asks-for-png ()
  "Probe must call `x-export-frames' with TYPE=png, not the PDF default.
Without the explicit format the trial export returns PDF bytes
\(`%PDF'), the magic-byte check fails, and the backend resolves to
`unavailable' -- making every screenshot tool fail silently.  Stub
the primitive and `display-graphic-p' to confirm the probe asks
for PNG."
  :tags '(:fast)
  (let ((emacs-devtools-mcp-tools-gui--host-backend nil)
        (received-type 'unset))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&rest _) t))
              ((symbol-function 'x-export-frames)
               (lambda (&optional _frames type)
                 (setq received-type type)
                 ;; Return real PNG magic so the probe accepts the
                 ;; backend.
                 "\x89PNG\r\n\x1a\n........")))
      (should (eq 'x-export-frames
                  (emacs-devtools-mcp-tools-gui--probe-host-backend))))
    (should (eq 'png received-type))))

(ert-deftest emacs-devtools-mcp-tests/screenshot-frame-real-png-via-spawn ()
  "End-to-end PNG round-trip: handler -> spawn -> `x-export-frames'.
Spawns a real subordinate daemon (which inherits DISPLAY from
`xvfb-run'), loads the package into it, creates a graphical X
frame, then drives the real `screenshot_frame' handler with a
`:spawn' target.  Asserts the returned base64 decodes to a real
PNG (magic header + non-trivial size).  Skipped when no DISPLAY
is set or when the subordinate cannot create a graphical frame
\(e.g. Emacs built without X support)."
  :tags '(:gui)
  (skip-unless (emacs-devtools-mcp-tests--daemon-available-p))
  (skip-unless (and (getenv "DISPLAY")
                    (not (string-empty-p (getenv "DISPLAY")))))
  (let ((lisp-dir
         (file-name-directory
          (or (locate-library "emacs-devtools-mcp-tools-gui")
              (error "package not on load-path -- run via `make test-gui'")))))
    (emacs-devtools-mcp-tests--with-empty-handles
     (let* ((rec (emacs-devtools-mcp-spawn-spawn))
            (handle (plist-get rec :handle))
            (target (list :spawn handle)))
       (unwind-protect
           (let ((bootstrap
                  ;; Load the package into the subordinate, reset its
                  ;; cached probe, create a graphical frame on the
                  ;; inherited DISPLAY, and select it so subsequent
                  ;; `x-export-frames' calls operate on it.  Returns t
                  ;; on success or (ERR . MSG) on failure -- the latter
                  ;; lets the host translate "no X support" into
                  ;; `ert-skip' instead of a hard fail.
                  (emacs-devtools-mcp-spawn-call
                   target
                   `(condition-case err
                        (progn
                          (add-to-list 'load-path ,lisp-dir)
                          ;; Require `-server' first so its
                          ;; `eval-after-load' fires cleanly and
                          ;; loads `-tools-gui' end-to-end.  Going
                          ;; direct via `(require 'tools-gui)' would
                          ;; recursively re-enter the load before the
                          ;; final `provide' and double-register every
                          ;; deftool.
                          (require 'emacs-devtools-mcp)
                          (require 'emacs-devtools-mcp-server)
                          (require 'emacs-devtools-mcp-tools-gui)
                          (setq emacs-devtools-mcp-tools-gui--host-backend
                                nil)
                          ;; Lift the export cap inside the subordinate
                          ;; so a higher-DPI desktop (where one char
                          ;; cell can exceed 50x20 px) does not push a
                          ;; trivially-small test frame past the
                          ;; 1920x1080 default.
                          (setq emacs-devtools-mcp-screenshot-max-pixels
                                (cons 4096 4096))
                          (let ((f (make-frame-on-display
                                    (getenv "DISPLAY")
                                    '((name . "edmcp-gui-test")
                                      (width . 40)
                                      (height . 12)))))
                            (select-frame f)
                            t))
                      (error (cons 'err (error-message-string err)))))))
             (unless (eq bootstrap t)
               (ert-skip
                (format "subordinate cannot create graphical frame: %S"
                        bootstrap)))
             (let* ((res (edmcp--tools-screenshot-frame
                          (list :target target)))
                    (content (plist-get res :content))
                    (blk (and (vectorp content)
                              (= 1 (length content))
                              (aref content 0)))
                    (b64 (plist-get blk :data))
                    (decoded (and (stringp b64) (base64-decode-string b64))))
               (should (equal "image" (plist-get blk :type)))
               (should (equal "image/png" (plist-get blk :mimeType)))
               (should (stringp b64))
               (should (> (length b64) 200))
               (should (>= (length decoded) 8))
               (should (equal (substring decoded 0 8)
                              "\x89PNG\r\n\x1a\n"))))
         (when (gethash handle emacs-devtools-mcp-spawn--handles)
           (ignore-errors (emacs-devtools-mcp-spawn-kill handle))))))))

(ert-deftest emacs-devtools-mcp-tests/gui-tools-registered ()
  "All six Phase 5 tools appear in the registry with correct names."
  :tags '(:fast)
  (dolist (name '("color_contrast" "face_at" "describe_face"
                  "list_faces" "get_frame_tree" "screenshot_frame"))
    (let ((rec (gethash name emacs-devtools-mcp--tool-registry)))
      (should rec)
      (should (functionp (plist-get rec :handler))))))

(ert-deftest emacs-devtools-mcp-tests/gui-tools-tools-list-includes-all ()
  "tools/list emits each Phase 5 tool with `readOnlyHint' set."
  :tags '(:fast)
  (let* ((res (edmcp--server-tools-list nil))
         (tools (append (plist-get res :tools) nil))
         (by-name (mapcar (lambda (t1) (plist-get t1 :name)) tools)))
    (dolist (n '("color_contrast" "face_at" "describe_face"
                 "list_faces" "get_frame_tree" "screenshot_frame"))
      (should (member n by-name)))
    (let ((rec (cl-find "color_contrast" tools
                        :key (lambda (e) (plist-get e :name))
                        :test #'string=)))
      (should (eq t (plist-get (plist-get rec :annotations)
                               :readOnlyHint))))))

;;;; ___Init___
;;
;; init.el tools that spawn transient `emacs -Q --batch' subprocesses:
;; `init-lint', `startup-profile', `bisect-init'.  Pure-logic tests
;; (registry/annotations, line classifier, form parser, allowlist) are
;; tagged `:fast'; tests that actually fork a batch Emacs are tagged
;; `:daemon' for parity with the spawn suite -- they cost ~0.5-2s each.

(defmacro emacs-devtools-mcp-tests--with-init-fixture (binding &rest body)
  "Bind BINDING (DIR FILE) to a temp dir + path inside it; run BODY.
The dir is added to `emacs-devtools-mcp-init-allowlist' for the
duration so `auth-validate-init-path' accepts files written under
it.  Caller is responsible for writing content to FILE."
  (declare (indent 1) (debug ((symbolp symbolp) body)))
  (pcase-let ((`(,dir-sym ,file-sym) binding))
    `(let* ((,dir-sym (make-temp-file "edmcp-init-fixture-" t))
            (,file-sym (expand-file-name "init.el" ,dir-sym))
            (emacs-devtools-mcp-init-allowlist
             (cons ,dir-sym emacs-devtools-mcp-init-allowlist)))
       (unwind-protect
           (progn ,@body)
         (when (file-directory-p ,dir-sym)
           (delete-directory ,dir-sym t))))))

(ert-deftest emacs-devtools-mcp-tests/init-tools-registered ()
  "All three Phase 8 tools appear in the registry with handlers."
  :tags '(:fast)
  (dolist (name '("init_lint" "startup_profile" "bisect_init"))
    (let ((rec (gethash name emacs-devtools-mcp--tool-registry)))
      (should rec)
      (should (functionp (plist-get rec :handler))))))

(ert-deftest emacs-devtools-mcp-tests/init-tools-list-includes-all ()
  "tools/list emits each Phase 8 tool with the expected hint shape."
  :tags '(:fast)
  (let* ((res (edmcp--server-tools-list nil))
         (tools (append (plist-get res :tools) nil))
         (by-name (mapcar (lambda (t1) (plist-get t1 :name)) tools)))
    (dolist (n '("init_lint" "startup_profile" "bisect_init"))
      (should (member n by-name)))
    (let ((lint (cl-find "init_lint" tools
                         :key (lambda (e) (plist-get e :name))
                         :test #'string=)))
      (should (eq t (plist-get (plist-get lint :annotations)
                               :readOnlyHint))))
    (let ((bisect (cl-find "bisect_init" tools
                           :key (lambda (e) (plist-get e :name))
                           :test #'string=)))
      (should (eq t (plist-get (plist-get bisect :annotations)
                               :destructiveHint))))))

(ert-deftest emacs-devtools-mcp-tests/init-lint-classify-line-error ()
  "Lines containing `Error:' are classified as `:error'."
  :tags '(:fast)
  (should (eq :error
              (edmcp--tools-init-lint-classify-line
               "init.el:42:0: Error: Wrong number of arguments"))))

(ert-deftest emacs-devtools-mcp-tests/init-lint-classify-line-warning ()
  "Lines containing `Warning:' are classified as `:warning'."
  :tags '(:fast)
  (should (eq :warning
              (edmcp--tools-init-lint-classify-line
               "Warning: assignment to free variable foo")))
  (should (eq :warning
              (edmcp--tools-init-lint-classify-line
               "Some warning: unused"))))

(ert-deftest emacs-devtools-mcp-tests/init-lint-classify-line-other ()
  "Plain prose lines classify as nil and stay only in :raw."
  :tags '(:fast)
  (should-not (edmcp--tools-init-lint-classify-line "Compiling foo.el..."))
  (should-not (edmcp--tools-init-lint-classify-line "")))

(ert-deftest emacs-devtools-mcp-tests/init-resolve-rejects-outside-allowlist ()
  "Path outside `init-allowlist' raises a `user-error' before any spawn."
  :tags '(:fast)
  (let ((tmp (make-temp-file "edmcp-outside-" nil ".el"))
        (emacs-devtools-mcp-init-allowlist '("/nonexistent-allowlist-xx")))
    (unwind-protect
        (should-error (edmcp--tools-init-resolve-file tmp)
                      :type 'user-error)
      (delete-file tmp))))

(ert-deftest emacs-devtools-mcp-tests/init-resolve-rejects-missing-file ()
  "A missing file under the allowlist still raises `user-error'."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (ignore file)
    (should-error
     (edmcp--tools-init-resolve-file
      (expand-file-name "does-not-exist.el" dir))
     :type 'user-error)))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-form-positions-counts ()
  "`bisect-form-positions' yields one entry per top-level form."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert "(setq a 1)\n(setq b 2)\n(setq c 3)\n"))
    (let ((positions (edmcp--tools-init-bisect-form-positions file)))
      (should (= 3 (length positions)))
      ;; Each form occupies a single line in this fixture.
      (should (equal 1 (plist-get (nth 0 positions) :line-start)))
      (should (equal 1 (plist-get (nth 0 positions) :line-end)))
      (should (equal 2 (plist-get (nth 1 positions) :line-start)))
      (should (equal 3 (plist-get (nth 2 positions) :line-end)))
      (should (numberp (plist-get (nth 0 positions) :end-pos))))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-form-positions-rejects-read-eval ()
  "An init file containing `#.' is refused before bisection."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file (insert "(setq x #.(emacs-pid))\n"))
    (should-error (edmcp--tools-init-bisect-form-positions file)
                  :type 'emacs-devtools-mcp-init-error)))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-form-positions-parse-error ()
  "An unbalanced init file signals a structured parse error."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file (insert "(setq a 1\n"))
    (should-error (edmcp--tools-init-bisect-form-positions file)
                  :type 'emacs-devtools-mcp-init-error)))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-bad-predicate-spawn-error ()
  "An unparseable predicate is wrapped as a tool-level error."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file (insert "(setq x 1)\n"))
    (should-error
     (edmcp--tools-init-bisect
      (list :file file :predicate "((((unbalanced"))
     :type 'emacs-devtools-mcp-init-error)))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-rejects-read-eval-predicate ()
  "A predicate containing `#.' is refused before any subprocess spawn."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file (insert "(setq x 1)\n"))
    (should-error
     (edmcp--tools-init-bisect
      (list :file file :predicate "#.(delete-file \"/tmp/never\")"))
     :type 'emacs-devtools-mcp-init-error)))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-handler-rejects-empty-predicate ()
  "Empty predicate string is rejected at the handler boundary."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file (insert "(setq x 1)\n"))
    (should-error (edmcp--tools-init-bisect
                   (list :file file :predicate ""))
                  :type 'emacs-devtools-mcp-init-error)))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-write-prefix-truncates ()
  "`bisect-write-prefix' writes exactly the first N forms verbatim."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert "(setq a 1)\n(setq b 2)\n(setq c 3)\n(setq d 4)\n"))
    (let* ((positions (edmcp--tools-init-bisect-form-positions file))
           (tmp (edmcp--tools-init-bisect-write-prefix file positions 2)))
      (unwind-protect
          (let ((content (with-temp-buffer
                           (insert-file-contents tmp)
                           (buffer-string))))
            (should (string-match-p "(setq a 1)" content))
            (should (string-match-p "(setq b 2)" content))
            (should-not (string-match-p "(setq c 3)" content)))
        (delete-file tmp)))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-write-prefix-preserves-cookie ()
  "Prefix slicing keeps the file's `lexical-binding' cookie intact."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";;; -*- lexical-binding:t -*-\n"
              "(setq a 1)\n(setq b 2)\n"))
    (let* ((positions (edmcp--tools-init-bisect-form-positions file))
           (tmp (edmcp--tools-init-bisect-write-prefix file positions 1)))
      (unwind-protect
          (let ((content (with-temp-buffer
                           (insert-file-contents tmp)
                           (buffer-string))))
            (should (string-match-p "lexical-binding:t" content))
            (should (string-match-p "(setq a 1)" content))
            (should-not (string-match-p "(setq b 2)" content)))
        (delete-file tmp)))))

;;;; ___Init (subprocess)___
;;
;; Tests below actually spawn `emacs -Q --batch'.  Tagged `:daemon' for
;; parity with the spawn suite; each costs ~0.5-2s.

(ert-deftest emacs-devtools-mcp-tests/init-lint-on-clean-file ()
  "A trivially valid init file lints with empty :warnings + :errors."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";;; clean -*- lexical-binding:t -*-\n"
              "(defun edmcp-clean-fixture () 42)\n"
              "(provide 'edmcp-clean)\n"))
    (let ((res (edmcp--tools-init-lint (list :file file))))
      (should (= 0 (plist-get res :exit_code)))
      (should (vectorp (plist-get res :warnings)))
      (should (vectorp (plist-get res :errors)))
      (should (= 0 (length (plist-get res :errors))))
      (should (stringp (plist-get res :raw))))))

(ert-deftest emacs-devtools-mcp-tests/init-lint-flags-warnings ()
  "An init file with `byte-compile-warnings' triggers fills :warnings."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";;; warning -*- lexical-binding:t -*-\n"
              ;; Reference an unknown free variable: classic warning.
              "(defun edmcp-warning-fixture () (+ 1 edmcp-undefined-var))\n"
              "(provide 'edmcp-warning)\n"))
    (let* ((res (edmcp--tools-init-lint (list :file file)))
           (warnings (append (plist-get res :warnings) nil)))
      (should (cl-some (lambda (l)
                         (string-match-p "edmcp-undefined-var" l))
                       warnings)))))

(ert-deftest emacs-devtools-mcp-tests/init-lint-rejects-outside-allowlist ()
  "init-lint handler refuses paths outside the allowlist before spawn."
  :tags '(:fast)
  (let ((tmp (make-temp-file "edmcp-outside-lint-" nil ".el"))
        (emacs-devtools-mcp-init-allowlist '("/nonexistent")))
    (unwind-protect
        (should-error (edmcp--tools-init-lint (list :file tmp))
                      :type 'user-error)
      (delete-file tmp))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-converges-on-bad-form ()
  "bisect-init pinpoints the form that causes the predicate to reproduce."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";;; bisect -*- lexical-binding:t -*-\n"
              "(setq edmcp-bisect-a 1)\n"
              "(setq edmcp-bisect-b 2)\n"
              ;; Form 4 is the culprit: provides a feature the predicate detects.
              "(setq edmcp-bisect-c 3)\n"
              "(provide 'edmcp-bisect-bad-feature)\n"
              "(setq edmcp-bisect-d 4)\n"
              "(setq edmcp-bisect-e 5)\n"))
    (let ((res (edmcp--tools-init-bisect
                (list :file file
                      :predicate "(featurep 'edmcp-bisect-bad-feature)"))))
      (should (equal 4 (plist-get res :culprit_form)))
      (should (= 6 (plist-get res :forms_total)))
      (should (numberp (plist-get res :line_start)))
      (should (numberp (plist-get res :line_end)))
      (should (numberp (plist-get res :probes)))
      ;; ceil(log2(6)) = 3 binary-search probes plus one full-file probe.
      (should (<= (plist-get res :probes) 8)))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-rejects-non-reproducing ()
  "bisect-init signals when predicate does not fire for the full file."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert "(setq a 1)\n(setq b 2)\n(setq c 3)\n"))
    (should-error
     (edmcp--tools-init-bisect
      (list :file file :predicate "(featurep 'never-provided)"))
     :type 'emacs-devtools-mcp-init-error)))

(ert-deftest emacs-devtools-mcp-tests/init-startup-profile-shape ()
  "startup-profile returns elapsed + samples + top, with redacted :raw."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";;; profile -*- lexical-binding:t -*-\n"
              "(dotimes (i 100) (cl-incf i))\n"
              "(provide 'edmcp-profile-fixture)\n"))
    (let ((res (edmcp--tools-init-startup-profile (list :file file))))
      (should (= 0 (plist-get res :exit_code)))
      (should (numberp (plist-get res :elapsed)))
      (should (>= (plist-get res :elapsed) 0))
      (should (numberp (plist-get res :samples)))
      (should (or (vectorp (plist-get res :top))
                  (listp (plist-get res :top))))
      (should (stringp (plist-get res :raw)))
      (should (eq :json-false (plist-get res :parse_error)))
      (should (eq :json-false (plist-get res :load_error))))))

(ert-deftest emacs-devtools-mcp-tests/init-startup-profile-surfaces-load-error ()
  "An init that fails to `require' a missing package surfaces `:load_error'.
This is the agent's escape hatch for the `-Q --batch' load-path
gotcha: the runner can't see ELPA, so any `(require \\='foo)' that
the user's normal startup would resolve via package autoloads
fails inside the probe.  Without `:load_error', the result looks
like a fast clean run (`exit_code 0', `samples 0', empty `:top'),
which hides the problem."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";;; -*- lexical-binding:t -*-\n"
              "(require 'edmcp-no-such-package-anywhere-12345)\n"))
    (let* ((res (edmcp--tools-init-startup-profile (list :file file)))
           (load-err (plist-get res :load_error)))
      (should (stringp load-err))
      (should (string-match-p "edmcp-no-such-package-anywhere-12345"
                              load-err)))))

(ert-deftest emacs-devtools-mcp-tests/init-batch-timeout-fires-on-hang ()
  "An init that loops forever is killed within the configured timeout."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    ;; A tight infinite loop — predicate would never run because load
    ;; itself never returns.
    (with-temp-file file
      (insert ";;; -*- lexical-binding:t -*-\n"
              "(while t (sit-for 0.01))\n"))
    (let ((emacs-devtools-mcp-init-batch-timeout 2)
          (start (float-time)))
      (should-error
       (edmcp--tools-init-startup-profile (list :file file))
       :type 'emacs-devtools-mcp-init-error)
      ;; Bound: timeout (2s) + drain (1s) + slack.
      (should (< (- (float-time) start) 6.0)))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-max-probes-respected ()
  "Bisection halts at `bisect-max-probes' even on a non-monotonic predicate."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";;; -*- lexical-binding:t -*-\n"
              "(setq a 1)\n(setq b 2)\n(setq c 3)\n"
              "(setq d 4)\n(setq e 5)\n(setq f 6)\n"
              "(setq g 7)\n(setq h 8)\n"))
    (let ((emacs-devtools-mcp-bisect-max-probes 3))
      ;; Predicate always reproduces; bisect has 8 forms, would take 4
      ;; probes (sanity + ceil(log2 8)) without the cap.
      (let ((res (edmcp--tools-init-bisect
                  (list :file file :predicate "t"))))
        (should (<= (plist-get res :probes) 3))))))

(ert-deftest emacs-devtools-mcp-tests/init-lint-redacts-auth-source-output ()
  "Output containing `auth-source-' lines is dropped from `:raw'."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      ;; A free-variable warning we know byte-compile will emit, with a
      ;; companion message that the redactor must scrub.
      (insert ";;; -*- lexical-binding:t -*-\n"
              "(message \"auth-source-secret hunter2\")\n"
              "(defun foo () (setq qzqzqz_unbound 1))\n"))
    (let ((res (edmcp--tools-init-lint (list :file file))))
      (should-not (string-match-p "auth-source-secret"
                                  (plist-get res :raw))))))

(ert-deftest emacs-devtools-mcp-tests/init-lint-classify-line-error-precedes-warning ()
  "Lines containing both `Error:' and `Warning:' classify as `:error'."
  :tags '(:fast)
  (should (eq :error
              (edmcp--tools-init-lint-classify-line
               "init.el:1:0: Error: foo (Warning: ignored)"))))

(ert-deftest emacs-devtools-mcp-tests/init-lint-classify-line-property ()
  "Random strings without `Error:'/`Warning:' classify as nil."
  :tags '(:fast)
  ;; Bounded random check: 200 short strings drawn from an alphabet that
  ;; excludes the trigger substrings entirely.
  (let* ((alphabet "abcdefghijklmnopqrstuvxyz0123456789 :;!?*"))
    (dotimes (_ 200)
      (let ((len (1+ (random 64)))
            (s ""))
        (dotimes (_ len)
          (setq s (concat s (string (aref alphabet
                                          (random (length alphabet)))))))
        (should-not (edmcp--tools-init-lint-classify-line s))))))

(ert-deftest emacs-devtools-mcp-tests/init-tools-call-end-to-end ()
  "init_lint dispatched via tools/call returns wrapped MCP content."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";;; -*- lexical-binding:t -*-\n(provide 'edmcp-e2e)\n"))
    (let* ((res (edmcp--server-tools-call
                 nil
                 (list :name "init_lint"
                       :arguments (list :file file)))))
      ;; Success envelope: {:content [...] :isError :json-false}.
      (should (vectorp (plist-get res :content)))
      (should (eq :json-false (plist-get res :isError)))
      ;; The text content block carries the result as JSON; verify the
      ;; snake_case fields the agent reads survived the wrapper.
      (let ((text (plist-get (aref (plist-get res :content) 0) :text)))
        (should (string-match-p "\"exit_code\"" text))
        (should (string-match-p "\"warnings\"" text))
        (should (string-match-p "\"errors\"" text))))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-form-positions-multiline-form ()
  "A form spanning multiple lines reports correct line-start/line-end."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert "(setq\n  one 1)\n(setq\n  two\n  2)\n"))
    (let ((positions (edmcp--tools-init-bisect-form-positions file)))
      (should (= 2 (length positions)))
      (should (equal 1 (plist-get (nth 0 positions) :line-start)))
      (should (equal 2 (plist-get (nth 0 positions) :line-end)))
      (should (equal 3 (plist-get (nth 1 positions) :line-start)))
      (should (equal 5 (plist-get (nth 1 positions) :line-end))))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-form-positions-tolerates-footer ()
  "A trailing `;;; foo.el ends here' footer parses cleanly.

Regression: the parser previously treated trailing `;'-comments
as parse-failure, since `read' raises `end-of-file' before
returning, and the recovery path's `(eq beg (point-max))' check
saw `beg' parked at the start of the comment.  Real-world init
files that follow the package convention always have such a
footer, so `bisect_init' refused to run on any of them."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";;; init.el --- my config -*- lexical-binding:t; -*-\n"
              "(setq foo 1)\n"
              "(setq bar 2)\n"
              "\n"
              ";;; init.el ends here\n"))
    (let ((positions (edmcp--tools-init-bisect-form-positions file)))
      (should (= 2 (length positions)))
      (should (equal 2 (plist-get (nth 0 positions) :line-start)))
      (should (equal 3 (plist-get (nth 1 positions) :line-start))))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-form-positions-tolerates-bare-footer ()
  "A file ending mid-comment with no newline still parses cleanly."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert "(setq a 1)\n(setq b 2)\n;;; eof"))
    (let ((positions (edmcp--tools-init-bisect-form-positions file)))
      (should (= 2 (length positions))))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-form-positions-interleaved-comments ()
  "Comment lines between forms do not change the form count."
  :tags '(:fast)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    (with-temp-file file
      (insert ";; preamble\n"
              "(setq a 1)\n"
              ";; middle\n"
              "(setq b 2)\n"
              ";; trailing\n"))
    (let ((positions (edmcp--tools-init-bisect-form-positions file)))
      (should (= 2 (length positions))))))

(ert-deftest emacs-devtools-mcp-tests/init-profile-redacts-frame-names ()
  "Frame strings inside `:top' are passed through `redact'."
  :tags '(:fast)
  (let* ((entry (edmcp--tools-init-redact-top-entry
                 (list :count 1
                       :frames '("ok"
                                 "auth-source-secret-leak"
                                 "epg-private")))))
    (should (= 1 (plist-get entry :count)))
    (let ((frames (plist-get entry :frames)))
      ;; Frames that match a redaction pattern are scrubbed; frames that
      ;; don't survive verbatim.
      (should (member "ok" frames))
      (should-not (cl-some (lambda (f)
                             (and (stringp f)
                                  (string-match-p "auth-source-secret-leak" f)))
                           frames)))))

(ert-deftest emacs-devtools-mcp-tests/init-profile-parse-error-flagged ()
  "When the sentinel is absent the result reports `:parse_error'."
  :tags '(:fast)
  (let ((pair (edmcp--tools-init-parse-profile-output "no sentinel here")))
    (should (null (car pair)))
    (should (stringp (cdr pair)))))

(ert-deftest emacs-devtools-mcp-tests/init-profile-parse-uses-last-sentinel ()
  "Earlier sentinel in init chatter cannot poison the parser."
  :tags '(:fast)
  ;; First (forged) payload claims 99 samples; real payload reports 7.
  (let* ((raw (concat "EDMCP-PROFILE-BEGIN\n(:elapsed 0.1 :samples 99 :top [])"
                      "\nEDMCP-PROFILE-END\n"
                      "EDMCP-PROFILE-BEGIN\n(:elapsed 0.5 :samples 7 :top [])"
                      "\nEDMCP-PROFILE-END\n"))
         (pair (edmcp--tools-init-parse-profile-output raw))
         (parsed (car pair)))
    (should parsed)
    (should (= 7 (plist-get parsed :samples)))))

(ert-deftest emacs-devtools-mcp-tests/init-bisect-load-fail-distinguished ()
  "A prefix that fails to load increments `:load_failed_probes'."
  :tags '(:daemon)
  (emacs-devtools-mcp-tests--with-init-fixture (dir file)
    ;; Form 1 is a hard load error; predicate is `t' so the probe would
    ;; otherwise classify as :reproduces.  Convergence still pins to 1
    ;; but the result discloses load_failed_probes >= 1.
    (with-temp-file file
      (insert ";;; -*- lexical-binding:t -*-\n"
              "(error \"deliberate load-time failure\")\n"))
    (let ((res (edmcp--tools-init-bisect
                (list :file file :predicate "t"))))
      (should (= 1 (plist-get res :culprit_form)))
      (should (>= (plist-get res :load_failed_probes) 1)))))

(provide 'emacs-devtools-mcp-tests)
;;; emacs-devtools-mcp-tests.el ends here
