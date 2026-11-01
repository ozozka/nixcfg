;;; my-agent-tests.el --- Native Pi regression tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests need only built-in Emacs.  Real offline Pi integration is opt-in:
;; MY_AGENT_TEST_PI=1 emacs --batch --no-init-file -L modules/dev/emacs \
;;   -l my-agent-tests -f ert-run-tests-batch-and-exit
;; No provider request, credentials or real sessions are used by integration.

;;; Code:
(require 'ert)
(require 'my-agent)

(defconst my-agent-test--root
  (file-name-directory (or load-file-name buffer-file-name)))
(defmacro my-agent-test--buffer (&rest body)
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (my-agent-mode) (my-agent--initialize)
     (unwind-protect (progn ,@body)
       (my-agent--cleanup))))

(ert-deftest my-agent-json-false-null ()
  (let ((data (my-agent--parse "{\"false\":false,\"null\":null,\"array\":[]}")))
    (should (eq (my-agent--get data "false") :false))
    (should (eq (my-agent--get data "null") :null))
    (should (equal (my-agent--json data) "{\"false\":false,\"null\":null,\"array\":[]}"))))

(ert-deftest my-agent-unicode-serialization-is-character-text ()
  (let* ((value (my-agent--object "text" "héllo\u2028world"))
         (json (my-agent--json value)))
    (should (multibyte-string-p json))
    (should (equal (my-agent--get (my-agent--parse json) "text") "héllo\u2028world"))
    (should (string-match-p "héllo" (my-agent--pretty value)))))

(ert-deftest my-agent-local-command-restored-prompt-is-not-erased ()
  (my-agent-test--buffer
   (my-agent--set-draft "/fork")
   (cl-letf (((symbol-function 'my-agent-fork) (lambda () (my-agent--set-draft "restored prompt"))))
     (should (my-agent--dispatch-slash "/fork"))
     (should (equal (my-agent--draft) "restored prompt")))))

(ert-deftest my-agent-final-response-reduced-before-exit ()
  (my-agent-test--buffer
   (let (answer)
     (puthash "1" (cons "prompt" (lambda (record) (setq answer (my-agent--get record "success"))))
              (my-agent--session-pending my-agent--session))
     (my-agent--enqueue 'rpc (my-agent--object "type" "response" "id" "1" "success" t))
     (my-agent--enqueue 'exit "finished")
     (my-agent--flush)
     (should (eq answer t))
     (should (equal (my-agent--session-phase my-agent--session) "stopped")))))

(ert-deftest my-agent-state-is-buffer-local ()
  (my-agent-test--buffer
   (let ((session my-agent--session))
     (my-agent-test--buffer
      (should-not (eq session my-agent--session))
      (should-not (eq (my-agent--session-index session) (my-agent--session-index my-agent--session)))
      (should-not (eq (my-agent--session-pending session) (my-agent--session-pending my-agent--session)))))))

(ert-deftest my-agent-stale-owner-is-inert ()
  (my-agent-test--buffer
   (let ((old my-agent--session) called)
     (my-agent--initialize)
     (my-agent--owned (current-buffer) old (lambda () (setq called t)))
     (should-not called))))

(ert-deftest my-agent-output-preserves-prompt-and-undo ()
  (my-agent-test--buffer
   (my-agent--set-draft "draft\nsecond line")
   (goto-char (- (point-max) 3))
   (let ((offset (- (point) (my-agent--session-prompt my-agent--session)))
         (undo buffer-undo-list))
     (my-agent--notice "Output" "streamed answer")
     (my-agent--flush)
     (should (equal (my-agent--draft) "draft\nsecond line"))
     (should (= offset (- (point) (my-agent--session-prompt my-agent--session))))
     (should (equal undo buffer-undo-list))
     (should-error (delete-region (point-min) (1+ (point-min))) :type 'text-read-only))))

(ert-deftest my-agent-updating-earlier-block-preserves-later-boundaries ()
  (my-agent-test--buffer
   (let ((a (my-agent--notice "First" "one")) (b (my-agent--notice "Second" "two")))
     (my-agent--flush)
     (my-agent--set-block a "longer first output\nnew line" nil)
     (my-agent--render-block a)
     (my-agent--set-block b "second replacement" nil)
     (my-agent--render-block b)
     (should (string-match-p "longer first output" (buffer-string)))
     (should (string-match-p "second replacement" (buffer-string)))
     (should (< (my-agent--block-start a) (my-agent--block-end a)))
     (should (<= (my-agent--block-end a) (my-agent--block-start b)))
     (should (<= (my-agent--block-end b) (my-agent--session-output my-agent--session))))))

(ert-deftest my-agent-unknown-record-is-visible-complete ()
  (my-agent-test--buffer
   (my-agent--event (my-agent--parse "{\"type\":\"future_event\",\"newField\":\"do not lose me\"}"))
   (my-agent--flush)
   (should (string-match-p "Unrecognized Pi output" (buffer-string)))
   (should (string-match-p "do not lose me" (buffer-string)))) )

(ert-deftest my-agent-streaming-deltas-reconcile-final-message ()
  (my-agent-test--buffer
   (my-agent--event (my-agent--parse "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"timestamp\":1,\"content\":[]}}"))
   (my-agent--event (my-agent--parse "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"partial\"}}"))
   (my-agent--flush)
   (should (string-match-p "partial" (buffer-string)))
   (my-agent--event (my-agent--parse "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"timestamp\":1,\"content\":[{\"type\":\"text\",\"text\":\"authoritative\"}]}}"))
   (my-agent--flush)
   (should (string-match-p "authoritative" (buffer-string)))
   (should-not (string-match-p "partial" (buffer-string)))) )

(ert-deftest my-agent-rendered-faces-survive-font-lock ()
  (my-agent-test--buffer
   (let ((block (my-agent--block "styled" 'assistant "Pi")))
     ;; Deterministic even without tree-sitter: this exercises transcript
     ;; ownership, independently of the Markdown parser's availability.
     (cl-letf (((symbol-function 'my-agent--markdown)
                (lambda (text) (propertize text 'face 'bold))))
       (my-agent--set-block block "Styled answer" nil)
       (my-agent--render-block block))
     (my-agent--set-draft "Editable prompt")
     (goto-char (point-min)) (search-forward "Styled answer")
     (let ((position (1- (point))))
       (should (eq (get-text-property position 'face) 'bold))
       ;; Redisplay/global font-lock and whitespace-mode request these passes
       ;; interactively; the original batch streaming tests did not.
       (font-lock-fontify-region (point-min) (point-max))
       (should (eq (get-text-property position 'face) 'bold))
       (font-lock-unfontify-region (point-min) (point-max))
       (should (eq (get-text-property position 'face) 'bold))
       (should (equal (my-agent--draft) "Editable prompt"))))))

(ert-deftest my-agent-redraw-keeps-live-session-and-draft ()
  (my-agent-test--buffer
   (let ((session my-agent--session)
         (block (my-agent--block "existing" 'assistant "Pi")))
     (my-agent--set-block block "Existing response" nil)
     (my-agent--set-draft "Unsent draft")
     (setf (my-agent--session-counter session) 91)
     ;; Simulate the font-lock settings of an already running, pre-fix buffer.
     (setq-local font-lock-fontify-region-function #'font-lock-default-fontify-region
                 font-lock-unfontify-region-function #'font-lock-default-unfontify-region)
     (my-agent-redraw)
     (my-agent--flush)
     (should (eq my-agent--session session))
     (should (= (my-agent--session-counter session) 91))
     (should (equal (my-agent--draft) "Unsent draft"))
     (should (eq font-lock-fontify-region-function #'my-agent--fontify-prompt))
     (should (eq font-lock-unfontify-region-function #'my-agent--unfontify-prompt)))))

(ert-deftest my-agent-markdown-preserves-code-block-overlay-faces ()
  (skip-unless (and (require 'markdown-ts-mode nil t)
                    (treesit-language-available-p 'markdown)
                    (treesit-language-available-p 'markdown-inline)))
  (let* ((rendered (my-agent--markdown "# Heading\n\n`inline`\n\n```text\nplain code\n```\n"))
         (heading (get-text-property (string-match "Heading" rendered) 'face rendered))
         (inline (get-text-property (string-match "inline" rendered) 'face rendered))
         (code-face (get-text-property (string-match "plain code" rendered) 'face rendered))
         (code (if (listp code-face) code-face (list code-face))))
    (should (memq 'markdown-ts-heading-1 heading))
    (should (memq 'markdown-ts-code-span inline))
    (should (or (memq 'markdown-ts-code-block code)
                (memq 'markdown-ts-code-block-markup-hidden code)))))

(ert-deftest my-agent-tools-expand-by-default-and-respect-manual-folds ()
  (my-agent-test--buffer
   (my-agent--delta (my-agent--parse "{\"assistantMessageEvent\":{\"type\":\"toolcall_start\",\"contentIndex\":0,\"id\":\"call\",\"toolName\":\"bash\"}}"))
   (let ((block (my-agent--tool "call")))
     (should-not (my-agent--block-collapsed block))
     (my-agent--flush)
     (my-agent--toggle block)
     (my-agent--event (my-agent--parse "{\"type\":\"tool_execution_start\",\"toolCallId\":\"call\",\"toolName\":\"bash\",\"args\":{\"command\":\"echo hi\"}}"))
     (should (my-agent--block-collapsed block))
     (my-agent-redraw t)
     (should-not (my-agent--block-collapsed block)))))

(ert-deftest my-agent-section-labels-are-fixed-pitch ()
  (my-agent-test--buffer
   (my-agent--message (my-agent--parse "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"text\"}]}"))
   (my-agent--flush)
   (goto-char (point-min))
   (dolist (text '("Thinking" "[data]"))
     (search-forward text)
     (should (memq 'fixed-pitch (get-text-property (1- (point)) 'face))))))

(ert-deftest my-agent-bash-presentation-is-literal-not-json ()
  (my-agent-test--buffer
   (let* ((block (my-agent--tool "shell" "bash"))
          (command "printf first\nprintf second")
          (result (my-agent--object "content" (vector (my-agent--object "type" "text" "text" "first\nsecond")))))
     (setf (my-agent--block-arguments block)
           (my-agent--object "command" command "timeout" 30 "futureArgument" "keep\nthis"))
     (let ((body (my-agent--tool-text block result)))
       (should (string-match-p (regexp-quote (concat "$ " command)) body))
       (should (string-match-p "Output\nfirst\nsecond" body))
       (should (string-match-p "futureArgument:\nkeep\nthis" body))
       (should-not (string-match-p "\\\"command\\\"" body))
       (should-not (string-match-p (regexp-quote "first\\n") body))))))

(ert-deftest my-agent-edit-result-shows-one-diff-and-keeps-unknown-fields ()
  (my-agent-test--buffer
   (let* ((block (my-agent--tool "edit" "edit"))
          (patch "--- a/test.el\n+++ b/test.el\n@@ -1 +1 @@\n-old\n+new\n")
          (record (my-agent--object "role" "toolResult" "toolCallId" "edit" "toolName" "edit"
                                    "content" (vector (my-agent--object "type" "text" "text" "Edited file"))
                                    "details" (my-agent--object "patch" patch "diff" "alternate raw representation"
                                                                "firstChangedLine" 1 "futureDetail" "line1\nline2"))))
     (setf (my-agent--block-arguments block)
           (my-agent--object "path" "test.el" "edits"
                             (vector (my-agent--object "oldText" "old" "newText" "new" "futureEdit" "keep me"))))
     (my-agent--message record t)
     (let ((body (my-agent--block-text block)))
       (should (= 1 (length (cdr (split-string body (regexp-quote "@@ -1 +1 @@"))))))
       (should (string-match-p "File: test.el" body))
       (should (string-match-p "futureEdit: keep me" body))
       (should (string-match-p "futureDetail:\nline1\nline2" body))
       (should-not (string-match-p "oldText\\|newText\\|Result details" body))
       (should (eq (my-agent--block-raw block) record))
       (should (equal (my-agent--get (my-agent--get record "details") "diff") "alternate raw representation"))))))

(ert-deftest my-agent-prompt-markdown-is-styled-but-fully-editable ()
  (skip-unless (and (require 'markdown-ts-mode nil t)
                    (treesit-language-available-p 'markdown)
                    (treesit-language-available-p 'markdown-inline)))
  (my-agent-test--buffer
   (let ((text "# Prompt\n\n**bold** and `inline`\n\n```text\ncode body\n```\n"))
     (my-agent--set-draft text)
     (my-agent--fontify-prompt (point-min) (point-max))
     (should (equal text (my-agent--draft)))
     (goto-char (my-agent--session-prompt my-agent--session))
     (dolist (sample '(("Prompt" . markdown-ts-heading-1) ("bold" . markdown-ts-bold) ("inline" . markdown-ts-code-span)))
       (search-forward (car sample))
       (let ((face (get-text-property (1- (point)) 'face)))
         (should (memq (cdr sample) (if (listp face) face (list face))))))
     (let ((position (marker-position (my-agent--session-prompt my-agent--session))))
       (while (< position (point-max))
         (should-not (get-text-property position 'read-only))
         (should-not (get-text-property position 'display))
         (should-not (get-text-property position 'invisible))
         (should-not (get-text-property position 'button))
         (setq position (1+ position)))))))

(ert-deftest my-agent-prompt-cache-and-undo-survive-streaming ()
  (my-agent-test--buffer
   (let ((calls 0) (original (symbol-function 'my-agent--markdown)))
     (my-agent--set-draft "**draft**")
     (undo-boundary)
     (cl-letf (((symbol-function 'my-agent--markdown)
                (lambda (text &optional editing)
                  (when editing (setq calls (1+ calls)))
                  (funcall original text editing))))
       (my-agent--fontify-prompt (point-min) (point-max))
       (my-agent--notice "Incoming" "Output while composing")
       (my-agent--flush)
       (my-agent--fontify-prompt (point-min) (point-max))
       (should (= calls 1)))
     (let ((inhibit-message t)) (undo-only 1))
     (should (equal (my-agent--draft) ""))
     (should (string-match-p "Output while composing" (buffer-string))))))

(ert-deftest my-agent-thinking-body-renders-markdown ()
  (skip-unless (and (require 'markdown-ts-mode nil t)
                    (treesit-language-available-p 'markdown)
                    (treesit-language-available-p 'markdown-inline)))
  (my-agent-test--buffer
   (my-agent--message (my-agent--parse "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"**Reasoning heading**\"}]}"))
   (my-agent--flush)
   (goto-char (point-min)) (search-forward "Reasoning heading")
   (should (memq 'markdown-ts-bold (get-text-property (1- (point)) 'face)))))

(defun my-agent-test--face-at (text)
  "Return the face list at the first occurrence of TEXT."
  (goto-char (point-min))
  (search-forward text)
  (let ((face (get-text-property (1- (point)) 'face)))
    (if (listp face) face (list face))))

(ert-deftest my-agent-streaming-prose-keeps-the-prose-face ()
  (my-agent-test--buffer
   (my-agent--event (my-agent--parse "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"timestamp\":1,\"content\":[]}}"))
   (my-agent--event (my-agent--parse "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"prose here\"}}"))
   (my-agent--flush)
   ;; Prose inherits the buffer's variable-pitch face, also while streaming.
   (should-not (memq 'fixed-pitch (my-agent-test--face-at "prose here")))
   ;; Tool bodies stay monospace.
   (my-agent--event (my-agent--parse "{\"type\":\"tool_execution_start\",\"toolCallId\":\"t1\",\"toolName\":\"bash\",\"args\":{\"command\":\"ls -la\"}}"))
   (my-agent--flush)
   (should (memq 'fixed-pitch (my-agent-test--face-at "ls -la")))))

(ert-deftest my-agent-streaming-appends-instead-of-re-rendering ()
  (my-agent-test--buffer
   (my-agent--event (my-agent--parse "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"timestamp\":1,\"content\":[]}}"))
   (let ((text "") (start nil))
     (dotimes (_ 40)
       (setq text (concat text "chunk "))
       (my-agent--event (my-agent--parse
                         (format "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"chunk \"}}")))
       (my-agent--flush))
     (setq start (float-time))
     (dotimes (_ 60)
       (setq text (concat text "chunk "))
       (my-agent--event (my-agent--parse
                         "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"chunk \"}}"))
       (my-agent--flush))
     ;; Appending must stay cheap: a full re-render per delta is quadratic.
     (should (< (- (float-time) start) 5.0))
     (let ((block (car (my-agent--session-blocks my-agent--session))))
       (should (equal (my-agent--block-rendered block) text))
       (should (string-match-p (regexp-quote (substring text (- (length text) 60))) (buffer-string)))
       ;; Exactly one body, not one per delta.
       (should (= 1 (length (my-agent--session-blocks my-agent--session))))))))

(ert-deftest my-agent-final-message-keeps-executed-tool-body ()
  (my-agent-test--buffer
   (dolist (record '(
		     "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"timestamp\":1,\"content\":[]}}"
		     "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"toolcall_start\",\"contentIndex\":0,\"id\":\"c1\",\"toolName\":\"bash\"}}"
		     "{\"type\":\"tool_execution_start\",\"toolCallId\":\"c1\",\"toolName\":\"bash\",\"args\":{\"command\":\"echo hi\"}}"
		     "{\"type\":\"tool_execution_end\",\"toolCallId\":\"c1\",\"toolName\":\"bash\",\"isError\":false,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"))
     (my-agent--event (my-agent--parse record)))
   (my-agent--flush)
   (should (string-match-p "hi" (my-agent--block-text (my-agent--tool "c1"))))
   ;; The final assistant message repeats the tool call without its result.
   (my-agent--event (my-agent--parse "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"timestamp\":1,\"content\":[{\"type\":\"toolCall\",\"id\":\"c1\",\"name\":\"bash\",\"arguments\":{\"command\":\"echo hi\"}}]}}"))
   (my-agent--flush)
   (should (string-match-p "hi" (my-agent--block-text (my-agent--tool "c1"))))))

(ert-deftest my-agent-field-order-is-deterministic ()
  (my-agent-test--buffer
   (let* ((args (my-agent--object "zeta" 1 "alpha" 2 "mu" 3 "beta" 4))
          (first (my-agent--tool-arguments args))
          (second (my-agent--tool-arguments args)))
     (should (equal first second))
     (should (< (string-match "alpha" first) (string-match "beta" first)))
     (should (< (string-match "beta" first) (string-match "mu" first)))
     (should (< (string-match "mu" first) (string-match "zeta" first))))))

(ert-deftest my-agent-thinking-folds-without-deletion ()
  (my-agent-test--buffer
   (my-agent--message (my-agent--parse "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"visible on expansion\"}]}"))
   (my-agent--flush)
   (let ((block (car (my-agent--session-blocks my-agent--session))))
     (should (my-agent--block-collapsed block))
     (should (string-match-p "visible on expansion" (buffer-string)))
     (should (overlay-get (my-agent--block-overlay block) 'invisible))
     (my-agent--toggle block)
     (should-not (overlay-get (my-agent--block-overlay block) 'invisible)))))

(ert-deftest my-agent-tool-result-retains-restored-call-arguments ()
  (my-agent-test--buffer
   (my-agent--message (my-agent--parse "{\"role\":\"assistant\",\"timestamp\":1,\"content\":[{\"type\":\"toolCall\",\"id\":\"call\",\"name\":\"read\",\"arguments\":{\"path\":\"important.txt\"}}]}" ) t)
   (my-agent--message (my-agent--parse "{\"role\":\"toolResult\",\"toolCallId\":\"call\",\"toolName\":\"read\",\"content\":[{\"type\":\"text\",\"text\":\"file contents\"}]}" ) t)
   (should (string-match-p "important.txt" (my-agent--block-text (my-agent--tool "call"))))
   (should (string-match-p "file contents" (my-agent--block-text (my-agent--tool "call"))))))

(ert-deftest my-agent-unknown-content-and-role ()
  (my-agent-test--buffer
   (my-agent--message (my-agent--parse "{\"role\":\"futureRole\",\"content\":[{\"type\":\"futureBlock\",\"payload\":\"retained\"}]}"))
   (my-agent--flush)
   (should (string-match-p "futureRole" (buffer-string)))
   (should (string-match-p "retained" (buffer-string)))))

(ert-deftest my-agent-agent-end-is-not-idle ()
  (my-agent-test--buffer
   (my-agent--event (my-agent--object "type" "agent_start"))
   (my-agent--event (my-agent--object "type" "agent_end"))
   (should-not (equal (my-agent--session-phase my-agent--session) "idle"))
   (my-agent--event (my-agent--object "type" "agent_settled"))
   (should (equal (my-agent--session-phase my-agent--session) "idle"))))

(ert-deftest my-agent-history-restores-draft ()
  (my-agent-test--buffer
   (setf (my-agent--session-history my-agent--session) '("previous"))
   (my-agent--set-draft "unfinished")
   (my-agent-history-previous) (should (equal (my-agent--draft) "previous"))
   (my-agent-history-next) (should (equal (my-agent--draft) "unfinished"))))

(ert-deftest my-agent-stderr-and-malformed-output-not-hidden ()
  (my-agent-test--buffer
   (my-agent--enqueue 'stderr "warning text")
   (my-agent--enqueue 'malformed '("stdout" . "not json"))
   (my-agent--flush)
   (should (string-match-p "warning text" (buffer-string)))
   (should (string-match-p "not json" (buffer-string)))))

(ert-deftest my-agent-async-editor-text-preserves-draft ()
  (my-agent-test--buffer
   (my-agent--set-draft "my draft")
   (my-agent--ui (my-agent--object "method" "set_editor_text" "text" "extension text"))
   (should (equal (my-agent--draft) "my draft\n\nextension text"))))

(ert-deftest my-agent-undo-survives-streaming-output ()
  (my-agent-test--buffer
   (goto-char (point-max))
   (insert "draft")
   (undo-boundary)
   (my-agent--notice "Output" "output shifts the editable region")
   (my-agent--flush)
   (let ((inhibit-message t)) (undo-only 1))
   (should (equal (my-agent--draft) ""))
   (should (string-match-p "output shifts" (buffer-string)))))

(ert-deftest my-agent-correlation-is-by-id-not-order ()
  (my-agent-test--buffer
   (let (a b)
     (puthash "1" (cons "get_state" (lambda (r) (setq a (my-agent--get r "data")))) (my-agent--session-pending my-agent--session))
     (puthash "2" (cons "get_state" (lambda (r) (setq b (my-agent--get r "data")))) (my-agent--session-pending my-agent--session))
     (my-agent--response (my-agent--object "id" "2" "success" t "data" "second"))
     (my-agent--response (my-agent--object "id" "1" "success" t "data" "first"))
     (should (equal a "first")) (should (equal b "second")))))

(ert-deftest my-agent-framing-only-splits-lf ()
  (my-agent-test--buffer
   (let ((process (make-pipe-process :name "Pi framing test" :noquery t)))
     (unwind-protect
         (progn
           (my-agent--filter (current-buffer) my-agent--session "stdout" process "{\"type\":\"future\",\"text\":\"hi")
           (should-not (my-agent--session-incoming my-agent--session))
           (my-agent--filter (current-buffer) my-agent--session "stdout" process "é\u2028there\"}\r\n{\"type\":\"another\"}\n")
           (my-agent--flush)
           (should (= 2 (length (my-agent--session-blocks my-agent--session))))
           (should (string-match-p "hié" (buffer-string))))
       (delete-process process)))))

(ert-deftest my-agent-repeat-message-does-not-duplicate-assistant ()
  (my-agent-test--buffer
   (let ((message (my-agent--parse "{\"role\":\"assistant\",\"timestamp\":1,\"content\":[{\"type\":\"text\",\"text\":\"answer\"}]}")))
     (my-agent--message message t)
     (my-agent--message message t)
     (should (= 1 (length (my-agent--session-blocks my-agent--session)))))))

(ert-deftest my-agent-parallel-tool-updates-stay-independent ()
  (my-agent-test--buffer
   (dolist (id '("parent/1" "parent/2"))
     (my-agent--event (my-agent--object "type" "tool_execution_start" "toolCallId" id "toolName" "read" "args" (my-agent--object "path" id))))
   (my-agent--event (my-agent--object "type" "tool_execution_end" "toolCallId" "parent/2" "toolName" "read" "result" (my-agent--object "content" (vector (my-agent--object "type" "text" "text" "second")))))
   (let ((a (my-agent--tool "parent/1")) (b (my-agent--tool "parent/2")))
     (should-not (eq a b))
     (should (equal "parent/1" (my-agent--get (my-agent--block-arguments a) "path")))
     (should (string-match-p "second" (my-agent--block-text b))))))

(defun my-agent-test--wait (predicate &optional seconds)
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline)) (accept-process-output nil 0.03))
    (should (funcall predicate))))

(ert-deftest my-agent-integration-offline-concurrent-streams-and-reload ()
  (skip-unless (getenv "MY_AGENT_TEST_PI"))
  (let* ((directory (make-temp-file "my-agent-test-" t))
         (default-directory directory)
         (process-environment (copy-sequence process-environment))
         (my-agent-log-directory (expand-file-name "logs" directory))
         (my-agent-adapter-file (expand-file-name "../pi/adapter.ts" my-agent-test--root))
         (status (expand-file-name "../pi/extensions/status.ts" my-agent-test--root))
         (fixture (expand-file-name "../pi/tests/frontend-fixture.ts" my-agent-test--root))
         (my-agent-arguments (list "--offline" "--no-session" "--no-extensions" "--no-mcp" "--no-context-files" "--extension" status "--extension" fixture))
         buffers)
    (setenv "PI_CODING_AGENT_DIR" (expand-file-name "config" directory))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "other-project" directory))
          (dotimes (i 3)
            (let ((buffer (generate-new-buffer " *Pi integration*")))
              (push buffer buffers)
              (with-current-buffer buffer
                (setq default-directory (if (= i 2) (expand-file-name "other-project" directory) directory))
                (my-agent-mode) (my-agent--initialize) (my-agent--start))))
          (dolist (buffer buffers)
            (with-current-buffer buffer
              (my-agent-test--wait (lambda () (and (my-agent--session-ready my-agent--session)
                                                   (member "snapshot" (my-agent--session-capabilities my-agent--session)))))
              (my-agent--set-draft (buffer-name))
              (let ((snapshot (my-agent--adapter-query "snapshot")))
                (should (equal (my-agent--get snapshot "cwd") (directory-file-name default-directory))))
              (should (equal "héllo" (my-agent--get (my-agent--query "bash" (my-agent--object "command" "printf héllo" "excludeFromContext" t)) "output")))
              (let ((done nil))
                (my-agent--rpc "bash" (my-agent--object "command" "printf first; sleep 0.15; printf second" "excludeFromContext" t)
                               (lambda (_) (setq done t)))
                (my-agent-test--wait (lambda () done))
                (my-agent--flush)
                (should (string-match-p "firstsecond" (buffer-string)))
                (should (equal (my-agent--draft) (buffer-name))))
              (my-agent--query "prompt" (my-agent--object "message" "/frontend-test"))
              (my-agent-test--wait (lambda () (string-match-p "Structured notification retained" (buffer-string))))
              (should (equal (gethash "fixture-status" (my-agent--session-statuses my-agent--session)) "Custom status retained"))
              (should (string-match-p "Second widget line" (buffer-string)))
              (my-agent--rpc "prompt" (my-agent--object "message" "/frontend-test dialog") (lambda (_) nil))
              (my-agent-test--wait (lambda () (my-agent--session-dialogs my-agent--session)))
              (my-agent--answer-dialog (car (my-agent--session-dialogs my-agent--session)) (my-agent--object "value" "Block"))
              (my-agent-test--wait (lambda () (string-match-p "Selected: Block" (buffer-string))))
              (my-agent-test--wait (lambda () (hash-table-p (my-agent--session-metrics my-agent--session))))
              (should (my-agent--get (my-agent--session-metrics my-agent--session) "activeMilliseconds"))
              (should (= #o700 (logand #o777 (file-modes (my-agent--session-log-directory my-agent--session)))))
              (let ((runtime (my-agent--session-runtime my-agent--session)))
                (my-agent-reload)
                (my-agent-test--wait (lambda () (and (not (equal runtime (my-agent--session-runtime my-agent--session)))
                                                     (my-agent--session-capabilities my-agent--session)))))))
          (with-current-buffer (car buffers) (my-agent-stop t))
          (with-current-buffer (cadr buffers) (should (my-agent--alive-p))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (my-agent-stop t) (setq kill-buffer-query-functions nil))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest my-agent-integration-trust-precedes-rpc-and-fails-closed ()
  (skip-unless (getenv "MY_AGENT_TEST_PI"))
  (let* ((directory (make-temp-file "my-agent-trust-" t))
         (default-directory directory)
         (process-environment (copy-sequence process-environment))
         (my-agent-log-directory (expand-file-name "logs" directory))
         (my-agent-adapter-file (expand-file-name "../pi/adapter.ts" my-agent-test--root))
         (my-agent-arguments '("--offline" "--no-session" "--no-extensions" "--no-mcp" "--no-context-files")))
    (setenv "PI_CODING_AGENT_DIR" (expand-file-name "config" directory))
    (make-directory (expand-file-name ".pi" directory))
    (write-region "{\"defaultThinkingLevel\":\"low\"}" nil (expand-file-name ".pi/settings.json" directory) nil 'silent)
    (unwind-protect
        (dolist (allow '(nil t))
          (with-temp-buffer
            (my-agent-mode) (my-agent--initialize)
            (unwind-protect
                (progn
                  (my-agent--start)
                  (my-agent-test--wait (lambda () (my-agent--session-dialogs my-agent--session)))
                  (should-not (my-agent--session-ready my-agent--session))
                  (my-agent--answer-dialog
                   (car (my-agent--session-dialogs my-agent--session))
                   (my-agent--object "trusted" (if allow t :false) "remember" :false))
                  (my-agent-test--wait (lambda () (member "snapshot" (my-agent--session-capabilities my-agent--session))))
                  (should (eq (my-agent--get (my-agent--adapter-query "snapshot") "trusted") (if allow t :false)))
                  (should-not (file-exists-p (expand-file-name "config/trust.json" directory))))
              (my-agent-stop t))))
      (delete-directory directory t))))

(provide 'my-agent-tests)
;;; my-agent-tests.el ends here
