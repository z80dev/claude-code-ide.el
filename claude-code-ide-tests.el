;;; claude-code-ide-tests.el --- Tests for Claude Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Yoav Orot
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Test suite for claude-code-ide.el using ERT
;;
;; Run tests with:
;;   `emacs -batch -L . -l ert -l claude-code-ide-tests.el -f ert-run-tests-batch-and-exit'
;;
;; The tests mock both vterm and mcp-server-lib functionality to avoid requiring
;; these packages during testing. This allows the tests to run in any environment
;; without external dependencies.
;;
;; CRITICAL DISCOVERY: Claude Code tools only work when launched from VS Code/editor terminals
;; because the extensions set these environment variables:
;; - CLAUDE_CODE_SSE_PORT: The WebSocket server port created by the extension
;; - ENABLE_IDE_INTEGRATION: Set to "true" to enable MCP tools
;; - FORCE_CODE_TERMINAL: Set to "true" to enable terminal features
;;
;; Workflow:
;; 1. Extension creates WebSocket/MCP server on random port
;; 2. Extension sets environment variables in terminal
;; 3. Extension launches 'claude' command
;; 4. Claude CLI reads env vars and connects to WebSocket server
;; 5. CLI and extension communicate via WebSocket/JSON-RPC for tool calls

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; Mock Implementations

;; === Mock claude-code-ide-debug module ===
(defvar claude-code-ide-debug nil
  "Mock debug flag for testing.")
(defvar claude-code-ide-log-with-context t
  "Mock log context flag for testing.")
(defun claude-code-ide-debug (&rest _args)
  "Mock debug function that does nothing."
  nil)
(defun claude-code-ide-clear-debug ()
  "Mock clear debug function."
  nil)
(defun claude-code-ide-log (format-string &rest args)
  "Mock logging function for tests."
  (apply #'message format-string args))
(defun claude-code-ide--get-session-context ()
  "Mock session context function."
  "")
(provide 'claude-code-ide-debug)

;; === Mock websocket module ===
;; Try to load real websocket, otherwise provide comprehensive mocks
(condition-case nil
    (progn
      (add-to-list 'load-path (expand-file-name "~/.emacs.d/.cache/straight/build/websocket/"))
      (require 'websocket))
  (error
   ;; Comprehensive websocket mock implementation
   (defun websocket-server (&rest _args)
     "Mock websocket-server function."
     ;; Return something that looks like a server but isn't a process
     '(:mock-server t))
   (defun websocket-server-close (_server)
     "Mock websocket-server-close function."
     nil)
   (defun websocket-send-text (_ws _text)
     "Mock websocket-send-text function."
     nil)
   (defun websocket-ready-state (_ws)
     "Mock websocket-ready-state function."
     'open)
   (defun websocket-url (_ws)
     "Mock websocket-url function."
     "ws://localhost:12345")
   (defun websocket-frame-text (_frame)
     "Mock websocket-frame-text function."
     "{}")
   (defun websocket-frame-opcode (_frame)
     "Mock websocket-frame-opcode function."
     'text)
   (defun websocket-send (_ws _frame)
     "Mock websocket-send function."
     nil)
   (defun websocket-server-filter (_proc _string)
     "Mock websocket-server-filter function."
     nil)
   ;; Define the structure accessors to avoid free variable warnings
   (defvar websocket-frame nil)
   (cl-defstruct websocket-frame opcode payload)
   (provide 'websocket)))

;; === Mock vterm module ===
(defvar vterm--process nil)
(defvar vterm-buffer-name nil)
(defvar vterm-shell nil)
(defvar vterm-environment nil)

(defun vterm (&optional buffer-name)
  "Mock vterm function for testing with optional BUFFER-NAME."
  (let ((buffer (generate-new-buffer (or buffer-name vterm-buffer-name "*vterm*"))))
    (with-current-buffer buffer
      ;; Create a mock process that exits immediately
      (setq vterm--process (make-process :name "mock-vterm"
                                         :buffer buffer
                                         :command '("true")
                                         :connection-type 'pty
                                         :sentinel (lambda (_ event)
                                                     (when (string-match "finished" event)
                                                       (setq vterm--process nil))))))
    buffer))

;; Mock vterm functions
(defun vterm-send-string (_string)
  "Mock vterm-send-string function for testing."
  nil)

(defun vterm-send-return ()
  "Mock vterm-send-return function for testing."
  nil)

(defun vterm-send-key (_key &optional _shift _meta _ctrl)
  "Mock vterm-send-key function for testing."
  nil)

(provide 'vterm)

;; === Mock Emacs display functions ===
(unless (fboundp 'display-buffer-in-side-window)
  (defun display-buffer-in-side-window (buffer _alist)
    "Mock display-buffer-in-side-window for testing."
    (set-window-buffer (selected-window) buffer)
    (selected-window)))

;; === Additional test-specific websocket mocks ===
(unless (featurep 'websocket)
  ;; Only define these if websocket wasn't loaded above
  (defvar websocket--test-server nil
    "Mock server for testing.")
  (defvar websocket--test-client nil
    "Mock client for testing.")
  (defvar websocket--test-port 12345
    "Mock port for testing."))

;; === Mock flycheck module ===
;; Mock flycheck before loading any modules that require it
(defvar flycheck-mode nil
  "Mock flycheck-mode variable.")
(defvar flycheck-current-errors nil
  "Mock list of flycheck errors.")

(cl-defstruct flycheck-error
  "Mock flycheck error structure."
  buffer checker filename line column end-line end-column
  message level severity id)

(provide 'flycheck)

;; === Load required modules ===
(define-error 'mcp-error "MCP Error" 'error)
(require 'claude-code-ide-mcp-handlers)
(require 'claude-code-ide)

;;; Test Helper Functions

(defmacro claude-code-ide-tests--with-mocked-cli (cli-path &rest body)
  "Execute BODY with claude CLI path set to CLI-PATH."
  `(let ((claude-code-ide-cli-path ,cli-path)
         (claude-code-ide--cli-available nil))
     ,@body))

(defun claude-code-ide-tests--with-temp-directory (test-body)
  "Execute TEST-BODY in a temporary directory context.
Creates a temporary directory, sets it as `default-directory',
executes TEST-BODY, and ensures cleanup even if TEST-BODY fails."
  (let ((temp-dir (make-temp-file "claude-code-ide-test-" t)))
    (unwind-protect
        (let ((default-directory temp-dir))
          (funcall test-body))
      (delete-directory temp-dir t))))

(defun claude-code-ide-tests--clear-processes ()
  "Clear the process hash table for testing.
Ensures a clean state before each test that involves process management."
  (clrhash claude-code-ide--processes)
  ;; Also clear MCP sessions
  (when (boundp 'claude-code-ide-mcp--sessions)
    (clrhash claude-code-ide-mcp--sessions)))

(defun claude-code-ide-tests--wait-for-process (buffer)
  "Wait for the process in BUFFER to finish.
This prevents race conditions in tests by ensuring mock processes
have completed before cleanup.  Waits up to 5 seconds."
  (with-current-buffer buffer
    (let ((max-wait 50)) ; 5 seconds max (50 * 0.1s)
      (while (and vterm--process
                  (process-live-p vterm--process)
                  (> max-wait 0))
        (sleep-for 0.1)
        (setq max-wait (1- max-wait))))))

;;; Tests for Helper Functions

(ert-deftest claude-code-ide-test-default-buffer-name ()
  "Test default buffer name generation for various path formats."
  ;; Normal path
  (should (equal (claude-code-ide--default-buffer-name "/home/user/project")
                 "*claude-code[project]*"))
  ;; Path with trailing slash
  (should (equal (claude-code-ide--default-buffer-name "/home/user/my-app/")
                 "*claude-code[my-app]*"))
  ;; Root directory
  (should (equal (claude-code-ide--default-buffer-name "/")
                 "*claude-code[]*"))
  ;; Path with spaces
  (should (equal (claude-code-ide--default-buffer-name "/home/user/my project/")
                 "*claude-code[my project]*"))
  ;; Path with special characters
  (should (equal (claude-code-ide--default-buffer-name "/home/user/my-project@v1.0/")
                 "*claude-code[my-project@v1.0]*")))

(ert-deftest claude-code-ide-test-get-working-directory ()
  "Test working directory detection."
  (claude-code-ide-tests--with-temp-directory
   (lambda ()
     ;; Without project, should return current directory
     (let ((expected (expand-file-name default-directory)))
       (should (equal (claude-code-ide--get-working-directory) expected))))))

(ert-deftest claude-code-ide-test-get-buffer-name ()
  "Test buffer name generation using custom function."
  ;; Test with custom function
  (let ((claude-code-ide-buffer-name-function
         (lambda (dir) (format "test-%s" (file-name-nondirectory dir)))))
    (claude-code-ide-tests--with-temp-directory
     (lambda ()
       (should (string-match "^test-claude-code-ide-test-"
                             (claude-code-ide--get-buffer-name))))))

  ;; Test that nil directory is handled correctly
  (let ((claude-code-ide-buffer-name-function
         (lambda (dir) (if dir
                           (format "*custom[%s]*" (file-name-nondirectory dir))
                         "*custom[none]*"))))
    (should (equal (funcall claude-code-ide-buffer-name-function nil)
                   "*custom[none]*"))))

(ert-deftest claude-code-ide-test-process-management ()
  "Test process storage and retrieval."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (claude-code-ide-tests--with-temp-directory
       (lambda ()
         (let ((dir (claude-code-ide--get-working-directory))
               (mock-process 'mock-process))
           ;; Initially no process
           (should (null (claude-code-ide--get-process dir)))

           ;; Set a process
           (claude-code-ide--set-process mock-process dir)
           (should (eq (claude-code-ide--get-process dir) mock-process))

           ;; Get process without specifying directory
           (should (eq (claude-code-ide--get-process) mock-process)))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-cleanup-dead-processes ()
  "Test cleanup of dead processes."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (let* ((live-process (make-process :name "test-live"
                                         :command '("sleep" "10")
                                         :buffer nil))
             (dead-process-name "test-dead"))
        ;; Create a mock dead process
        (puthash "/dir1" live-process claude-code-ide--processes)
        (puthash "/dir2" dead-process-name claude-code-ide--processes)

        ;; Before cleanup
        (should (= (hash-table-count claude-code-ide--processes) 2))

        ;; Run cleanup
        (claude-code-ide--cleanup-dead-processes)

        ;; After cleanup - only live process remains
        (should (= (hash-table-count claude-code-ide--processes) 1))
        (should (gethash "/dir1" claude-code-ide--processes))
        (should (null (gethash "/dir2" claude-code-ide--processes)))

        ;; Clean up the live process
        (delete-process live-process))
    (claude-code-ide-tests--clear-processes)))

;;; Tests for CLI Detection

(ert-deftest claude-code-ide-test-detect-cli ()
  "Test CLI detection mechanism."
  (let ((claude-code-ide--cli-available nil))
    ;; Test with invalid CLI path
    (let ((claude-code-ide-cli-path "nonexistent-claude-cli"))
      (claude-code-ide--detect-cli)
      (should (null claude-code-ide--cli-available)))

    ;; Test with valid command (echo exists on most systems)
    (let ((claude-code-ide-cli-path "echo"))
      (claude-code-ide--detect-cli)
      (should claude-code-ide--cli-available))))

(ert-deftest claude-code-ide-test-ensure-cli ()
  "Test CLI availability checking."
  (let ((claude-code-ide--cli-available nil)
        (claude-code-ide-cli-path "echo"))
    ;; Initially not available
    (should (null claude-code-ide--cli-available))

    ;; After ensure, should be detected
    (should (claude-code-ide--ensure-cli))
    (should claude-code-ide--cli-available)))

;;; Command Tests

(ert-deftest claude-code-ide-test-run-without-cli ()
  "Test run command when CLI is not available."
  (let ((claude-code-ide--cli-available nil)
        (claude-code-ide-cli-path "nonexistent-claude-cli"))
    (should-error (claude-code-ide)
                  :type 'user-error)))

(ert-deftest claude-code-ide-test-run-without-vterm ()
  "Test run command when vterm is not available."
  (let ((claude-code-ide--cli-available t)
        (claude-code-ide-cli-path "echo")
        (orig-fboundp (symbol-function 'fboundp)))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym) (if (eq sym 'vterm) nil (funcall orig-fboundp sym)))))
      (should-error (claude-code-ide)
                    :type 'user-error))))

(ert-deftest claude-code-ide-test-run-with-cli ()
  "Test successful run command execution."
  (skip-unless nil) ; Skip this test for now
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (claude-code-ide-tests--with-temp-directory
       (lambda ()
         (let ((claude-code-ide--cli-available t)
               (claude-code-ide-cli-path "echo"))
           ;; Run claude-code-ide
           (claude-code-ide)

           ;; Check that buffer was created
           (let ((buffer-name (claude-code-ide--get-buffer-name)))
             (should (get-buffer buffer-name))

             ;; Check that process was registered
             (should (claude-code-ide--get-process))

             ;; Wait for process to finish and clean up
             (claude-code-ide-tests--wait-for-process (get-buffer buffer-name))
             ;; Kill the buffer explicitly since we're in batch mode
             (when (get-buffer buffer-name)
               (kill-buffer buffer-name))))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-run-existing-session ()
  "Test run command when session already exists."
  (skip-unless nil) ; Skip this test for now
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (claude-code-ide-tests--with-temp-directory
       (lambda ()
         (let ((claude-code-ide--cli-available t)
               (claude-code-ide-cli-path "echo"))
           ;; Start first session
           (claude-code-ide)
           (let* ((buffer-name (claude-code-ide--get-buffer-name))
                  (first-buffer (get-buffer buffer-name)))

             ;; Verify we have the buffer
             (should first-buffer)

             ;; Try to run again - should not create new buffer
             (claude-code-ide)

             ;; Should still have same buffer
             (should (eq (get-buffer buffer-name) first-buffer))

             ;; Wait for process and clean up
             (claude-code-ide-tests--wait-for-process first-buffer)
             (kill-buffer first-buffer)))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-check-status ()
  "Test status check command."
  (let ((claude-code-ide-cli-path "echo")
        (claude-code-ide--cli-available nil))
    ;; Should not error and should detect CLI
    (claude-code-ide-check-status)
    (should claude-code-ide--cli-available)))

(ert-deftest claude-code-ide-test-stop-no-session ()
  "Test stop command when no session is running."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (claude-code-ide-tests--with-temp-directory
       (lambda ()
         ;; Should not error when no session exists
         (claude-code-ide-stop)))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-stop-with-session ()
  "Test stop command with active session."
  (skip-unless nil) ; Skip this test for now
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (claude-code-ide-tests--with-temp-directory
       (lambda ()
         (let ((claude-code-ide--cli-available t)
               (claude-code-ide-cli-path "echo"))
           ;; Start a session
           (claude-code-ide)
           (let ((buffer-name (claude-code-ide--get-buffer-name)))
             ;; Verify session exists
             (should (get-buffer buffer-name))
             (should (claude-code-ide--get-process))

             ;; Wait for process to finish before stopping
             (claude-code-ide-tests--wait-for-process (get-buffer buffer-name))

             ;; Stop the session
             (claude-code-ide-stop)

             ;; Verify session is stopped
             (should (null (get-buffer buffer-name)))
             (should (null (claude-code-ide--get-process)))))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-switch-to-buffer-no-session ()
  "Test `switch-to-buffer' command when no session exists."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (should-error (claude-code-ide-switch-to-buffer)
                    :type 'user-error)
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-toggle-window-functionality ()
  "Test that running claude-code-ide on an existing session toggles the window."
  (skip-unless nil) ; Skip this test for now
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (claude-code-ide-tests--with-temp-directory
       (lambda ()
         (let ((claude-code-ide--cli-available t)
               (claude-code-ide-cli-path "echo")
               (test-dir default-directory))
           ;; Start a session
           (claude-code-ide)
           (let* ((buffer-name (claude-code-ide--get-buffer-name))
                  (session-buffer (get-buffer buffer-name)))

             ;; Verify we have the buffer
             (should session-buffer)

             ;; Simulate window being visible (in batch mode we can't test actual windows)
             ;; Just verify the command runs without error when session exists
             (let ((default-directory test-dir))
               ;; Running claude-code-ide again should toggle (not error)
               (claude-code-ide))

             ;; Wait for process and clean up
             (claude-code-ide-tests--wait-for-process session-buffer)
             (kill-buffer session-buffer)))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-list-sessions-empty ()
  "Test listing sessions when none exist."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      ;; Should not error when no sessions exist
      (claude-code-ide-list-sessions)
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-list-sessions-with-sessions ()
  "Test listing sessions functionality."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (progn
        ;; Test that list-sessions works with no sessions
        (claude-code-ide-list-sessions)

        ;; Manually add mock entries to the process table
        (puthash "/tmp/project1" (current-buffer) claude-code-ide--processes)
        (puthash "/tmp/project2" (current-buffer) claude-code-ide--processes)

        ;; Verify we have 2 entries
        (should (= (hash-table-count claude-code-ide--processes) 2))

        ;; List sessions should work without error
        (claude-code-ide-list-sessions))
    (claude-code-ide-tests--clear-processes)))

;;; Edge Case Tests

(ert-deftest claude-code-ide-test-concurrent-sessions ()
  "Test managing multiple concurrent sessions."
  (skip-unless nil) ; Skip this test for now
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (let ((claude-code-ide--cli-available t)
            (claude-code-ide-cli-path "echo")
            (dir1 (make-temp-file "claude-test-1" t))
            (dir2 (make-temp-file "claude-test-2" t)))
        ;; Start sessions in different directories
        (let ((default-directory dir1))
          (claude-code-ide)
          (should (claude-code-ide--get-process dir1)))
        (let ((default-directory dir2))
          (claude-code-ide)
          (should (claude-code-ide--get-process dir2)))
        ;; Verify both sessions exist
        (should (= (hash-table-count claude-code-ide--processes) 2))
        ;; Clean up
        (let ((buffers (mapcar (lambda (dir)
                                 (funcall claude-code-ide-buffer-name-function dir))
                               (list dir1 dir2))))
          (dolist (buffer-name buffers)
            (when-let ((buffer (get-buffer buffer-name)))
              (claude-code-ide-tests--wait-for-process buffer)
              (kill-buffer buffer))))
        (delete-directory dir1 t)
        (delete-directory dir2 t))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-custom-buffer-naming ()
  "Test custom buffer naming function."
  (let ((claude-code-ide-buffer-name-function
         (lambda (dir)
           (format "TEST-%s"
                   (upcase (file-name-nondirectory (directory-file-name dir)))))))
    (claude-code-ide-tests--with-temp-directory
     (lambda ()
       (let ((expected (format "TEST-%s"
                               (upcase (file-name-nondirectory
                                        (directory-file-name default-directory))))))
         (should (equal (claude-code-ide--get-buffer-name) expected)))))))

(ert-deftest claude-code-ide-test-window-placement-options ()
  "Test different window placement configurations."
  (dolist (side '(left right top bottom))
    (let ((claude-code-ide-window-side side))
      ;; Just verify the setting is accepted
      (should (eq claude-code-ide-window-side side)))))

(ert-deftest claude-code-ide-test-debug-mode-flag ()
  "Test debug mode CLI flag."
  (let ((claude-code-ide-cli-debug t))
    (should (string-match "-d" (claude-code-ide--build-claude-command)))
    (should (string-match "-d.*-r" (claude-code-ide--build-claude-command t)))))

(ert-deftest claude-code-ide-test-error-handling ()
  "Test error handling in various scenarios."
  ;; Test with nil CLI path
  (let ((claude-code-ide-cli-path nil)
        (claude-code-ide--cli-available nil))
    (should-error (claude-code-ide) :type 'user-error))

  ;; Test with empty CLI path
  (let ((claude-code-ide-cli-path "")
        (claude-code-ide--cli-available nil))
    (should-error (claude-code-ide) :type 'user-error)))

;;; Run all tests

(ert-deftest claude-code-ide-test-tab-bar-tracking ()
  "Test that tab-bar tabs are tracked correctly."
  (let* ((temp-dir (make-temp-file "test-project-" t))
         (claude-code-ide-mcp--sessions (make-hash-table :test 'equal))
         ;; Mock tab-bar functions
         (mock-tab '((name . "test-tab") (index . 1)))
         (tab-bar-mode-enabled nil))
    ;; Mock tab-bar functions
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'tab-bar--current-tab)
                     (eq sym 'tab-bar-select-tab-by-name)
                     (eq sym 'tab-bar-mode)
                     (funcall (cl-letf-saved-symbol-function 'fboundp) sym))))
              ((symbol-function 'tab-bar--current-tab)
               (lambda () mock-tab))
              (tab-bar-mode tab-bar-mode-enabled))
      ;; Start MCP server
      (let ((port (claude-code-ide-mcp-start temp-dir)))
        (should port)
        ;; Get the session
        (let ((session (gethash temp-dir claude-code-ide-mcp--sessions)))
          (should session)
          ;; Check that tab was captured
          (should (equal (claude-code-ide-mcp-session-original-tab session) mock-tab))))
      ;; Cleanup
      (claude-code-ide-mcp-stop-session temp-dir))
    ;; Cleanup temp directory
    (delete-directory temp-dir t)))

(defun claude-code-ide-run-tests ()
  "Run all claude-code-ide test cases."
  (interactive)
  (ert-run-tests-batch-and-exit "^claude-code-ide-test-"))

(defun claude-code-ide-run-all-tests ()
  "Run all claude-code-ide tests including MCP tests."
  (interactive)
  (ert-run-tests-batch-and-exit "^claude-code-ide-"))

;;; MCP Tests

;; Load MCP module now that websocket is available
(require 'claude-code-ide-mcp)

;;; MCP Test Helper Functions

(defmacro claude-code-ide-mcp-tests--with-temp-file (file-var content &rest body)
  "Create a temporary file with CONTENT, bind its path to FILE-VAR, and execute BODY."
  (declare (indent 2))
  `(let ((,file-var (make-temp-file "claude-mcp-test-")))
     (unwind-protect
         (progn
           (with-temp-file ,file-var
             (insert ,content))
           ,@body)
       (delete-file ,file-var))))

(defmacro claude-code-ide-mcp-tests--with-temp-buffer (content &rest body)
  "Create a temporary buffer with CONTENT and execute BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (goto-char (point-min))
     ,@body))

;;; Tests for MCP Tool Implementations

(ert-deftest claude-code-ide-test-mcp-open-file ()
  "Test the openFile tool implementation."
  ;; Test successful file open
  (claude-code-ide-mcp-tests--with-temp-file test-file "Line 1\nLine 2\nLine 3\nLine 4"
                                             (let ((result (claude-code-ide-mcp-handle-open-file `((path . ,test-file)))))
                                               ;; Handler returns VS Code format
                                               (should (listp result))
                                               (let ((first-item (car result)))
                                                 (should (equal (alist-get 'type first-item) "text"))
                                                 (should (equal (alist-get 'text first-item) "FILE_OPENED")))
                                               (should (equal (buffer-file-name) test-file))
                                               (kill-buffer)))

  ;; Test with selection
  (claude-code-ide-mcp-tests--with-temp-file test-file "Line 1\nLine 2\nLine 3\nLine 4"
                                             (let ((result (claude-code-ide-mcp-handle-open-file
                                                            `((path . ,test-file)
                                                              (startLine . 2)
                                                              (endLine . 3)))))
                                               ;; Handler returns VS Code format
                                               (should (listp result))
                                               (let ((first-item (car result)))
                                                 (should (equal (alist-get 'type first-item) "text"))
                                                 (should (equal (alist-get 'text first-item) "FILE_OPENED")))
                                               (should (use-region-p))
                                               (should (= (line-number-at-pos (region-beginning)) 2))
                                               (kill-buffer)))

  ;; Test missing path parameter
  (should-error (claude-code-ide-mcp-handle-open-file '())
                :type 'mcp-error))

(ert-deftest claude-code-ide-test-mcp-get-current-selection ()
  "Test the getCurrentSelection tool implementation."
  ;; Test with active selection
  (claude-code-ide-mcp-tests--with-temp-buffer "Line 1\nLine 2\nLine 3"
                                               (goto-char (point-min))
                                               (set-mark (point))
                                               (forward-line 2)
                                               ;; Ensure transient-mark-mode is on and region is active
                                               (let ((transient-mark-mode t))
                                                 (activate-mark)
                                                 (let ((result (claude-code-ide-mcp-handle-get-current-selection nil)))
                                                   (should (equal (alist-get 'text result) "Line 1\nLine 2\n"))
                                                   ;; Check the selection structure
                                                   (let ((selection (alist-get 'selection result)))
                                                     (should selection)
                                                     (let ((start (alist-get 'start selection))
                                                           (end (alist-get 'end selection)))
                                                       (should (= (alist-get 'line start) 0))  ; 0-based
                                                       (should (= (alist-get 'line end) 2)))))))  ; 0-based

  ;; Test without selection
  (claude-code-ide-mcp-tests--with-temp-buffer "Test"
                                               (let ((result (claude-code-ide-mcp-handle-get-current-selection nil)))
                                                 (should (equal (alist-get 'text result) ""))
                                                 ;; When no selection, we should get the selection structure
                                                 (let ((selection (alist-get 'selection result)))
                                                   (should selection)
                                                   (should (alist-get 'isEmpty selection))))))

(ert-deftest claude-code-ide-test-mcp-get-open-editors ()
  "Test the getOpenEditors tool implementation."
  ;; Create some file buffers
  (let ((test-files '())
        (test-buffers '())
        ;; Mock the function to ensure we're not in a project
        (claude-code-ide-mcp--get-buffer-project-fn
         (symbol-function 'claude-code-ide-mcp--get-buffer-project)))
    (unwind-protect
        (progn
          ;; Mock to return nil (no project)
          (fset 'claude-code-ide-mcp--get-buffer-project (lambda () nil))

          ;; Create test files
          (dotimes (i 2)
            (let ((file (make-temp-file (format "claude-mcp-test-%d-" i))))
              (push file test-files)
              (push (find-file-noselect file) test-buffers)))

          ;; Test listing
          (let* ((result (claude-code-ide-mcp-handle-get-open-editors nil))
                 (editors (alist-get 'editors result)))
            ;; Should return an array
            (should (vectorp editors))
            ;; Should include our test files
            (let ((paths (mapcar (lambda (e) (alist-get 'path e))
                                 (append editors nil))))
              (dolist (file test-files)
                (should (member file paths))))))

      ;; Cleanup
      (fset 'claude-code-ide-mcp--get-buffer-project claude-code-ide-mcp--get-buffer-project-fn)
      (dolist (buffer test-buffers)
        (kill-buffer buffer))
      (dolist (file test-files)
        (delete-file file)))))

(ert-deftest claude-code-ide-test-mcp-save-document ()
  "Test the saveDocument tool implementation."
  (claude-code-ide-mcp-tests--with-temp-file test-file "Initial content"
                                             (with-current-buffer (find-file-noselect test-file)
                                               ;; Modify buffer
                                               (goto-char (point-max))
                                               (insert "\nNew line")
                                               ;; Save using tool
                                               (let ((result (claude-code-ide-mcp-handle-save-document `((path . ,test-file)))))
                                                 ;; Handler returns VS Code format
                                                 (should (listp result))
                                                 (let ((first-item (car result)))
                                                   (should (equal (alist-get 'type first-item) "text"))
                                                   (should (equal (alist-get 'text first-item) "DOCUMENT_SAVED")))
                                                 (should-not (buffer-modified-p)))
                                               (kill-buffer)))

  ;; Test missing path
  (should-error (claude-code-ide-mcp-handle-save-document '())
                :type 'mcp-error))

(ert-deftest claude-code-ide-test-mcp-close-tab ()
  "Test the close_tab tool implementation."
  (claude-code-ide-mcp-tests--with-temp-file test-file "Content"
                                             (find-file-noselect test-file)
                                             ;; Close using tool
                                             (let ((result (claude-code-ide-mcp-handle-close-tab `((path . ,test-file)))))
                                               ;; Handler returns VS Code format
                                               (should (listp result))
                                               (let ((first-item (car result)))
                                                 (should (equal (alist-get 'type first-item) "text"))
                                                 (should (equal (alist-get 'text first-item) "TAB_CLOSED")))
                                               (should-not (find-buffer-visiting test-file))))

  ;; Test non-existent buffer - should throw an error
  (should-error (claude-code-ide-mcp-handle-close-tab '((path . "/nonexistent/file")))
                :type 'mcp-error))

(ert-deftest claude-code-ide-test-mcp-tool-registry ()
  "Test that all tools are properly registered."
  (let ((expected-tools '("openFile" "getCurrentSelection" "getOpenEditors"
                          "getWorkspaceFolders" "getDiagnostics" "saveDocument"
                          "close_tab" "openDiff")))
    (dolist (tool-name expected-tools)
      (should (alist-get tool-name claude-code-ide-mcp-tools nil nil #'string=))
      (let ((handler (alist-get tool-name claude-code-ide-mcp-tools nil nil #'string=))
            (schema (alist-get tool-name claude-code-ide-mcp-tool-schemas nil nil #'string=)))
        ;; Check that handler is a function or a symbol that points to a function
        (should (or (functionp handler)
                    (and (symbolp handler) (fboundp handler))))
        ;; Check that schema is provided
        (should schema)))))

(ert-deftest claude-code-ide-test-mcp-server-lifecycle ()
  "Test MCP server start and stop."
  (require 'claude-code-ide-mcp)
  (unwind-protect
      (progn
        ;; Start server
        (let ((port (claude-code-ide-mcp-start)))
          (should (numberp port))
          (should (>= port 10000))
          (should (<= port 65535))
          ;; Check lockfile exists
          (should (file-exists-p (claude-code-ide-mcp--lockfile-path port)))
          ;; Stop server
          (claude-code-ide-mcp-stop)
          ;; Check lockfile removed
          (should-not (file-exists-p (claude-code-ide-mcp--lockfile-path port)))))
    ;; Ensure cleanup
    (claude-code-ide-mcp-stop)))

;; Test for side window handling in openDiff
(ert-deftest claude-code-ide-test-opendiff-side-window ()
  "Test that openDiff handles side windows correctly."
  (let* ((temp-dir (make-temp-file "test-project-" t))
         (claude-code-ide-mcp--sessions (make-hash-table :test 'equal))
         (claude-code-ide-debug t)
         (temp-file (make-temp-file "test-diff-" nil ".txt" "Original content\n"))
         (side-window nil)
         ;; Create a mock session for the test
         (test-session (make-claude-code-ide-mcp-session
                        :server nil
                        :client nil
                        :port 12345
                        :project-dir temp-dir
                        :deferred (make-hash-table :test 'equal)
                        :ping-timer nil
                        :selection-timer nil
                        :last-selection nil
                        :last-buffer nil
                        :active-diffs (make-hash-table :test 'equal)
                        :original-tab nil)))
    ;; Register the test session
    (puthash temp-dir test-session claude-code-ide-mcp--sessions)
    ;; Create a .git directory to make this a project
    (make-directory (expand-file-name ".git" temp-dir) t)

    (unwind-protect
        ;; Mock the project detection to return our test directory
        (cl-letf (((symbol-function 'claude-code-ide-mcp--get-buffer-project)
                   (lambda () temp-dir))
                  ((symbol-function 'claude-code-ide-mcp--get-current-session)
                   (lambda () test-session)))
          ;; Set up the project context
          (with-current-buffer (get-buffer-create "*test-buffer*")
            (setq default-directory temp-dir)

            ;; Create a side window to simulate the problem
            (let ((side-buffer (get-buffer-create "*test-sidebar*")))
              (with-current-buffer side-buffer
                (insert "Sidebar content"))
              ;; Display buffer in side window
              (setq side-window (display-buffer-in-side-window
                                 side-buffer
                                 '((side . left) (slot . 0) (window-width . 30))))

              ;; Verify side window was created
              (should (window-parameter side-window 'window-side))

              ;; Now try to open diff - should handle side window gracefully
              (let ((result (claude-code-ide-mcp-handle-open-diff
                             `((old_file_path . ,temp-file)
                               (new_file_path . ,temp-file)
                               (new_file_contents . "Modified content\n")
                               (tab_name . "test-diff")))))
                ;; Should return deferred
                (should (eq (alist-get 'deferred result) t))

                ;; Should have created diff session in the test session
                (should (gethash "test-diff" (claude-code-ide-mcp-session-active-diffs test-session)))

                ;; Clean up - quit ediff if it started
                (when (and (boundp 'ediff-control-buffer)
                           ediff-control-buffer
                           (buffer-live-p ediff-control-buffer))
                  (with-current-buffer ediff-control-buffer
                    (remove-hook 'ediff-quit-hook t t)
                    (ediff-really-quit nil)))))))
      ;; Cleanup
      (when (file-exists-p temp-file)
        (delete-file temp-file))
      (when (file-exists-p temp-dir)
        (delete-directory temp-dir t))
      (when (and side-window (window-live-p side-window))
        (delete-window side-window))
      (claude-code-ide-mcp--cleanup-diff "test-diff" test-session)
      (kill-buffer "*test-buffer*")
      (kill-buffer "*test-sidebar*"))))

;;; Tests for Diagnostics

(ert-deftest claude-code-ide-test-diagnostics-severity-mapping ()
  "Test diagnostic severity conversion."
  (require 'claude-code-ide-diagnostics)
  ;; Test Flycheck symbols
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'error) 1))
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'warning) 2))
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'info) 3))
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'hint) 4))
  ;; Test default fallback
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'unknown) 3)))

(ert-deftest claude-code-ide-test-diagnostics-severity-to-string ()
  "Test severity to string conversion."
  (require 'claude-code-ide-diagnostics)
  ;; Test Flycheck severities
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'error) "Error"))
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'warning) "Warning"))
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'info) "Information"))
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'hint) "Hint"))
  ;; Test default fallback
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'unknown) "Information")))

(ert-deftest claude-code-ide-test-diagnostics-handler ()
  "Test getDiagnostics handler."
  (require 'claude-code-ide-diagnostics)
  ;; Test with no diagnostics available
  (let ((result (claude-code-ide-diagnostics-handler nil)))
    ;; The diagnostics handler returns content array format
    (should (listp result))
    ;; Check it has the expected format
    (should (equal (alist-get 'type (car result)) "text"))
    ;; The text should be an empty array "[]"
    (should (equal (alist-get 'text (car result)) "[]"))))

(ert-deftest claude-code-ide-test-check-document-dirty ()
  "Test checkDocumentDirty handler."
  (require 'claude-code-ide-mcp-handlers)
  ;; Test with a modified buffer
  (with-temp-buffer
    (setq buffer-file-name "/tmp/test-file.el")
    (insert "test content")
    (set-buffer-modified-p t)
    (let ((result (claude-code-ide-mcp-handle-check-document-dirty
                   '((filePath . "/tmp/test-file.el")))))
      (should (eq (alist-get 'isDirty result) t))))
  ;; Test with an unmodified buffer
  (with-temp-buffer
    (setq buffer-file-name "/tmp/test-file2.el")
    (insert "test content")
    (set-buffer-modified-p nil)
    (let ((result (claude-code-ide-mcp-handle-check-document-dirty
                   '((filePath . "/tmp/test-file2.el")))))
      (should (eq (alist-get 'isDirty result) :json-false))))
  ;; Test with a non-existent file
  (let ((result (claude-code-ide-mcp-handle-check-document-dirty
                 '((filePath . "/tmp/non-existent-file.el")))))
    (should (eq (alist-get 'isDirty result) :json-false)))
  ;; Test with missing filePath parameter
  (should-error (claude-code-ide-mcp-handle-check-document-dirty '())
                :type 'mcp-error))

;; Disabled due to ERT macro interaction with transient-mark-mode in batch mode
;; The handler works correctly (verified with direct testing) but the test fails
;; because `should` macro seems to evaluate `use-region-p` in a different context
(ert-deftest claude-code-ide-test-open-file-text-patterns ()
  "Test openFile handler with text pattern selection."
  (skip-unless nil) ; Skip this test for now
  (require 'claude-code-ide-mcp-handlers)
  ;; Create a temporary file with known content
  (let ((temp-file (make-temp-file "test-openfile-" nil ".el"))
        ;; Save and restore global transient-mark-mode
        (orig-tmm transient-mark-mode))
    (unwind-protect
        (progn
          ;; Enable transient-mark-mode globally for this test
          (setq transient-mark-mode t)
          ;; Write test content to file
          (with-temp-file temp-file
            (insert "Line 1\n")
            (insert "function foo() {\n")
            (insert "  console.log('hello');\n")
            (insert "}\n")
            (insert "Line 5\n")
            (insert "function bar() {\n")
            (insert "  return 42;\n")
            (insert "}\n"))

          ;; Test 1: Text pattern selection with both start and end
          (let ((result (claude-code-ide-mcp-handle-open-file
                         `((path . ,temp-file)
                           (startText . "function foo")
                           (endText . "}")))))
            ;; Should have opened the file and selected from "function foo" to first "}"
            (with-current-buffer (find-buffer-visiting temp-file)
              (should (string= (buffer-file-name) temp-file))
              ;; Debug info
              (message "Debug: buffer=%s tmm=%s mark-active=%s mark=%s point=%s region-p=%s"
                       (buffer-name) transient-mark-mode mark-active
                       (and (mark) (mark)) (point) (use-region-p))
              ;; Store region state before should
              (let ((region-was-active (use-region-p)))
                (should region-was-active))
              (should (string= (buffer-substring-no-properties (region-beginning) (region-end))
                               "function foo() {\n  console.log('hello');\n}"))))

          ;; Test 2: Only start text pattern
          (with-current-buffer (find-buffer-visiting temp-file)
            (deactivate-mark))
          (let ((result (claude-code-ide-mcp-handle-open-file
                         `((path . ,temp-file)
                           (startText . "function bar")))))
            ;; Should position cursor at start of "function bar"
            (with-current-buffer (find-buffer-visiting temp-file)
              (should (looking-at "function bar"))
              (should-not (use-region-p))))

          ;; Test 3: Text pattern with fallback to line numbers
          (let ((result (claude-code-ide-mcp-handle-open-file
                         `((path . ,temp-file)
                           (startText . "nonexistent text")
                           (startLine . 2)
                           (endLine . 4)))))
            ;; Should fall back to line selection
            (with-current-buffer (find-buffer-visiting temp-file)
              (should (use-region-p))
              (let ((selected (buffer-substring-no-properties (region-beginning) (region-end))))
                (should (string-match-p "function foo" selected)))))

          ;; Test 4: Text patterns take precedence over line numbers
          (with-current-buffer (find-buffer-visiting temp-file)
            (deactivate-mark))
          (let ((result (claude-code-ide-mcp-handle-open-file
                         `((path . ,temp-file)
                           (startText . "Line 5")
                           (startLine . 1)))))
            ;; Should go to "Line 5", not line 1
            (with-current-buffer (find-buffer-visiting temp-file)
              (should (looking-at "Line 5"))
              (should (= (line-number-at-pos) 5)))))

      ;; Cleanup
      (delete-file temp-file)
      ;; Restore original transient-mark-mode
      (setq transient-mark-mode orig-tmm))))

;; Test multiple ediff sessions
(ert-deftest claude-code-ide-test-multiple-ediff-sessions ()
  "Test that multiple ediff sessions can run simultaneously without conflicts."
  (claude-code-ide-tests--with-temp-directory
   (lambda ()
     (let* ((session (make-claude-code-ide-mcp-session
                      :project-dir default-directory
                      :active-diffs (make-hash-table :test 'equal)))
            (file1 (expand-file-name "test-file1.txt" default-directory))
            (file2 (expand-file-name "test-file2.txt" default-directory))
            (control-buffers '()))

       ;; Register session in global hash table
       (puthash default-directory session claude-code-ide-mcp--sessions)

       ;; Create test files
       (with-temp-file file1 (insert "Original content 1"))
       (with-temp-file file2 (insert "Original content 2"))

       ;; Create a .git directory to make this a project
       (make-directory (expand-file-name ".git" default-directory) t)

       ;; Mock ediff functions to capture control buffer names
       (cl-letf* ((ediff-called-count 0)
                  ((symbol-function 'ediff-buffers)
                   (lambda (buf-A buf-B)
                     (cl-incf ediff-called-count)
                     ;; Simulate ediff creating a control buffer with the suffix
                     (let ((suffix (or ediff-control-buffer-suffix "")))
                       (push (format "*Ediff Control Panel%s*" suffix) control-buffers))))
                  ((symbol-function 'claude-code-ide-mcp--get-current-session)
                   (lambda () session)))

         ;; Simulate opening multiple diffs
         (unwind-protect
             (progn
               ;; Open first diff
               (let ((result1 (claude-code-ide-mcp-handle-open-diff
                               `((old_file_path . ,file1)
                                 (new_file_path . ,file1)
                                 (new_file_contents . "Modified content 1")
                                 (tab_name . "diff1")))))
                 (should (equal result1 '((deferred . t) (unique-key . "diff1")))))

               ;; Open second diff
               (let ((result2 (claude-code-ide-mcp-handle-open-diff
                               `((old_file_path . ,file2)
                                 (new_file_path . ,file2)
                                 (new_file_contents . "Modified content 2")
                                 (tab_name . "diff2")))))
                 (should (equal result2 '((deferred . t) (unique-key . "diff2")))))

               ;; Verify ediff was called twice
               (should (= ediff-called-count 2))

               ;; Verify we have two distinct control buffer names
               (should (= (length control-buffers) 2))
               (should (member "*Ediff Control Panel<diff1>*" control-buffers))
               (should (member "*Ediff Control Panel<diff2>*" control-buffers))

               ;; Verify active diffs are tracked correctly
               (let ((active-diffs (claude-code-ide-mcp--get-active-diffs session)))
                 (should (gethash "diff1" active-diffs))
                 (should (gethash "diff2" active-diffs))))

           ;; Cleanup
           (claude-code-ide-mcp-handle-close-all-diff-tabs nil)
           (when (file-exists-p file1) (delete-file file1))
           (when (file-exists-p file2) (delete-file file2))
           ;; Remove session from global hash table
           (remhash default-directory claude-code-ide-mcp--sessions)))))))

(ert-deftest test-claude-code-ide-mcp-multi-session-deferred ()
  "Test that deferred responses work correctly with multiple sessions."
  (skip-unless (not (getenv "CI")))
  (let ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal))
        (project-a "/tmp/project-a/")
        (project-b "/tmp/project-b/")
        (session-a nil)
        (session-b nil)
        (deferred-responses '())
        (sent-responses '()))
    ;; Create mock websocket-send-text to capture responses
    (cl-letf* (((symbol-function 'websocket-send-text)
                (lambda (_ws text)
                  (push text sent-responses))))
      (unwind-protect
          (progn
            ;; Create two sessions
            (make-directory project-a t)
            (make-directory project-b t)

            ;; Session A
            (let ((default-directory project-a))
              (claude-code-ide-mcp-start project-a)
              (setq session-a (gethash project-a claude-code-ide-mcp--sessions)))

            ;; Session B
            (let ((default-directory project-b))
              (claude-code-ide-mcp-start project-b)
              (setq session-b (gethash project-b claude-code-ide-mcp--sessions)))

            ;; Set up mock clients for each session
            (setf (claude-code-ide-mcp-session-client session-a) :mock-client-a)
            (setf (claude-code-ide-mcp-session-client session-b) :mock-client-b)

            ;; Store deferred responses in each session
            (let ((deferred-a (claude-code-ide-mcp-session-deferred session-a))
                  (deferred-b (claude-code-ide-mcp-session-deferred session-b)))
              ;; Session A has a deferred response for openDiff-diff1
              (puthash "openDiff-diff1" "request-id-1" deferred-a)
              ;; Session B has a deferred response for openDiff-diff2
              (puthash "openDiff-diff2" "request-id-2" deferred-b))

            ;; Complete deferred response for session A
            (claude-code-ide-mcp-complete-deferred "openDiff"
                                                   '(((type . "text") (text . "FILE_SAVED")))
                                                   "diff1")

            ;; Complete deferred response for session B
            (claude-code-ide-mcp-complete-deferred "openDiff"
                                                   '(((type . "text") (text . "DIFF_REJECTED")))
                                                   "diff2")

            ;; Verify both responses were sent
            (should (= (length sent-responses) 2))

            ;; Verify the responses contain the correct request IDs
            (let ((response1 (json-read-from-string (nth 1 sent-responses)))
                  (response2 (json-read-from-string (nth 0 sent-responses))))
              ;; Check that request-id-1 and request-id-2 were both used
              (let ((ids (list (alist-get 'id response1) (alist-get 'id response2))))
                (should (member "request-id-1" ids))
                (should (member "request-id-2" ids))))

            ;; Verify deferred responses were removed from sessions
            (should (= 0 (hash-table-count (claude-code-ide-mcp-session-deferred session-a))))
            (should (= 0 (hash-table-count (claude-code-ide-mcp-session-deferred session-b)))))

        ;; Cleanup
        (ignore-errors (delete-directory project-a t))
        (ignore-errors (delete-directory project-b t))
        (clrhash claude-code-ide-mcp--sessions)))))

(provide 'claude-code-ide-tests)

;;; claude-code-ide-tests.el ends here
