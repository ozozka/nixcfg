;;; my-agent.el --- Isolated native Pi sessions -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; DESIGN (Pi 1.4, Emacs 31; built-ins only)
;;
;; One agent = one buffer, Pi subprocess, saved session, environment snapshot,
;; private socket and collection of mutable state.  There is deliberately no
;; global current agent, registry, request counter, history or timer.  Discovery
;; scans buffer-list.  Only configuration, faces and keymaps are global.
;; Callbacks capture the owner AND session object; late output after restart
;; cannot target another agent.  Same-project agents share files, not sessions:
;; use Git worktrees when filesystem isolation is also required.
;;
;; Pi RPC owns prompting, models, tools, queues and persistence.  adapter.ts is
;; explicitly loaded, not discovered globally.  Its private Unix socket handles
;; early project trust and structured pi.events telemetry without corrupting RPC
;; stdout or writing status ticks into model context/session JSONL.  Publishers
;; (status.ts/notify.ts) never import or negotiate with this frontend.
;;
;; The transcript and editable prompt occupy ONE buffer.  Markers delimit the
;; prompt; output is read-only, rear-nonsticky, outside prompt undo history.
;; Streaming is reduced into blocks and redisplayed in batches, never by erasing
;; the whole transcript.  Each Markdown body is fontified in an isolated scratch
;; buffer so an unfinished fence cannot swallow the next message/tool.  We copy
;; presentation properties, not tree-sitter state or executable local variables.
;; STREAMING COST: a growing answer is appended, never re-rendered as a whole.
;; Re-inserting a body would invalidate its fontification on every delta and
;; turn one answer into quadratic work; measured cost of full re-render was
;; ~40s for a 12k-character answer.  Streaming bodies are therefore plain text
;; with a fixed-pitch or buffer face, and Markdown is parsed exactly once when
;; the authoritative final message replaces the speculative deltas.
;; Overlay faces (notably fixed-pitch code-block styling) are materialized into
;; text properties before leaving the scratch buffer. The transcript owns those
;; faces: ordinary font-lock/whitespace passes are restricted to the prompt, or
;; redisplay would erase the copied Markdown faces after they were inserted.
;;
;; PRESENTATION: three planes instead of one stream.  The transcript carries
;; the conversation only: a human turn ("YOU" label plus Markdown), a model
;; answer (Markdown, no label), thinking (one muted marker line) and tool
;; cards (heading plus body).  System noise never enters the transcript: it is
;; collected in a per-agent compilation buffer (C-c C-e) and counted in the
;; status line.  The composer is the last region of the buffer, flat and
;; unmarked by a surface, separated by a thin rule in the overlay colour; it
;; has a placeholder and attachment chips and renders live Markdown once the
;; draft stopped changing, so typing never pays for a parse.  Hierarchy comes
;; from color, weight and vertical rhythm: no borders, no indentation, no
;; nesting.  Machine content (tool headings, commands, code, diffs) is
;; monospace; human content (answers, thinking) is proportional.  Tool cards
;; state what they did: read names the file and the line range, bash shows the
;; command in its heading and its output in the body, edit shows one diff,
;; write shows the written content.  The header line holds the live metrics
;; in Pi's own order (tokens in, tokens out, cache reads, cache writes, cost
;; and the context share with its window) and the mode line the identity of
;; the agent.
;;
;; Prose is variable-pitch; section labels/tools/code/diffs are fixed-pitch.
;; Tools start expanded; thinking is a single line with nothing to expand. Tool arguments
;; use native multiline commands/files/replacements and a single result diff,
;; rather than duplicated JSON-escaped patch strings. Unknown fields still get
;; a visible generic representation; the complete record stays retrievable.
;; The editable prompt is isolated Markdown too, but copies faces only: syntax
;; stays visible and editing/undo never operate on hidden markup or buttons.
;; Prompt rendering is cached per buffer; streamed transcript changes do not
;; cause the same draft to be parsed repeatedly. Rendering falls back
;; visibly to plain text if grammars are unavailable.  Remote images are NOT
;; fetched automatically.  Inline image bytes received from Pi may be displayed.
;;
;; LOSSLESS POLICY: received stdout, adapter and stderr chunks are appended to
;; private files before decoding/presentation.  Unknown records, methods, content
;; types and malformed lines have visible generic sections, not silent default
;; branches.  Every section has a data inspector.  Tools fold, never truncate;
;; a thinking section is summarised by its marker and keeps its text in the
;; record, the log and Pi's session file.  Tool partial-result semantics are
;; tool-specific: show the latest
;; snapshot and retain every earlier update in raw logs.  Final messages replace
;; speculative deltas.  Compaction never deletes the human transcript.  Restoring
;; history walks raw entries, not only compacted get_messages.  Transient updates
;; survive in frontend logs, not necessarily in Pi's persisted JSONL.
;;
;; Logs can contain source, credentials exposed by tools, and prompts.  They are
;; 0600 under a 0700 directory, never in Nix, rotated, uploaded or shared silently.
;; A logging failure is visible and incoming chunks remain in a private buffer.
;; Users explicitly delete logs when no longer needed.  No secrets are requested
;; from pi auth print-* or copied into the Nix store.
;;
;; Lifecycle: subscribe/read before prompting; correlate by id; agent_end is NOT
;; idle (retries/overflow/queued work may follow).  agent_settled is authoritative.
;; Abort clears queues before stopping, restoring text.  Closing stdin requests
;; orderly shutdown; force termination is explicit.  Dialogs are pending actions
;; in the owning buffer (C-c C-d), never minibuffers opened by process filters.
;; Failed/expired/unknown interactions never imply consent.  Project trust is
;; decided before project extensions load, via the adapter's early trust hook.
;;
;; COMPATIBILITY: native RPC first, supported adapter operations second, explicit
;; CLI handoff last.  RPC cannot execute custom TUI components, terminal editor/
;; input factories or interactive login/share/bug screens.  Pi may make such calls
;; no-ops without emitting a record: no client can recover output never sent.
;; /help lists native controls; arbitrary RPC is available with my-agent-rpc.
;; Unknown slash commands require confirmation before being sent as ordinary
;; input.  Extension commands/templates/skills come from Pi, not hardcoded copies.
;; CLI handoff stops this writer before resuming the exact saved session.
;;
;; ENTRY POINTS: M-x my-agent (focus/select), my-agent-new (always independent).
;; Prefix my-agent-new asks for directory/name.  No automatic resume-on-create.
;; C-c C-c send/steer, C-c C-f follow-up, C-c C-k abort, C-c C-d answer dialog,
;; C-c C-e event log, C-c C-s statistics, C-c C-p menu, C-c C-o fold all, TAB
;; toggle/complete, M-p/M-n prompt history, RET inspect the record at point.
;; Numbers answer a pending question while the cursor is inside its card.
;; Nix injects program/adapter paths through the existing my-options interface.
;; Tests: emacs --batch --no-init-file -L modules/dev/emacs -l my-agent-tests
;;          -f ert-run-tests-batch-and-exit

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'project)
(require 'button)
(require 'ansi-color)
(require 'thingatpt)
(require 'rx)
(defvar markdown-ts-mode-hook)
(defvar markdown-ts-view-mode-hook)
(defvar markdown-ts-inline-images)
(defvar markdown-ts-hide-markup)
(defvar diff-mode-hook)
(defvar sh-mode-hook)
(declare-function markdown-ts-view-mode "markdown-ts-mode")
(declare-function notifications-notify "notifications")
(declare-function term-mode "term")
(declare-function term-char-mode "term")

(defgroup my-agent nil "Native Pi sessions." :group 'tools)
(defcustom my-agent-program "pi" "Pi executable." :type 'file :group 'my-agent)
(defcustom my-agent-adapter-file nil "Explicitly loaded adapter.ts, injected by Nix."
  :type '(choice (const nil) file) :group 'my-agent)
(defcustom my-agent-arguments nil "Additional trusted Pi CLI arguments."
  :type '(repeat string) :group 'my-agent)
(defcustom my-agent-log-directory
  (expand-file-name "emacs/pi/" (or (getenv "XDG_STATE_HOME") (expand-file-name "~/.local/state/")))
  "Private persistent logs.  Delete explicitly; never automatically shared."
  :type 'directory :group 'my-agent)
(defcustom my-agent-request-timeout 30 "Seconds for interactive control queries."
  :type 'number :group 'my-agent)
(defcustom my-agent-compose-delay 0.06
  "Seconds of silence before the composer is rendered as Markdown.
Live Markdown must not make typing expensive; the composer is rendered once
after the draft stops changing, exactly like Emacs defers fontification."
  :type 'number :group 'my-agent)
(defcustom my-agent-composer-rule-width 24
  "Number of columns of the thin rule drawn above the composer."
  :type 'number :group 'my-agent)
(defcustom my-agent-event-limit 5000
  "Maximum number of lines kept in the per-agent events buffer."
  :type 'number :group 'my-agent)
(defcustom my-agent-composer-placeholder "Ask…  / commands  ! shell  @ files"
  "Hint shown while the composer is empty."
  :type 'string :group 'my-agent)

(defun my-agent--theme-value (variable fallback)
  "Return the value of VARIABLE when it is usable, otherwise FALLBACK.
The Nix generated option file provides colors, fonts and heights; this
frontend also runs in a bare batch Emacs, so every value has a fallback."
  (let ((value (and (boundp variable) (symbol-value variable))))
    (if (or (null value) (equal value "")) fallback value)))

(defun my-agent--theme-height (variable fallback)
  "Return a usable face height from VARIABLE, otherwise FALLBACK.
Heights are 1/12 point units; accept both numbers and numeric strings."
  (let ((value (my-agent--theme-value variable nil)))
    (cond ((numberp value) (if (> value 0) value fallback))
          ((stringp value) (let ((number (string-to-number value)))
                             (if (> number 0) number fallback)))
          (t fallback))))

(defvar my-agent--color-primary (my-agent--theme-value 'my-theme-col-p "#09bea8")
  "Accent color: tool names, success, links.")
(defvar my-agent--color-secondary (my-agent--theme-value 'my-theme-col-s "#ff3963")
  "Attention color: failures and declines.")
(defvar my-agent--color-foreground (my-agent--theme-value 'my-theme-col-f "#ffffff")
  "Body text color.")
(defvar my-agent--color-muted (my-agent--theme-value 'my-theme-col-m "#7e8180")
  "Secondary text color.")
(defvar my-agent--color-overlay (my-agent--theme-value 'my-theme-col-o "#101212")
  "Surface color used to tint the composer.")
(defvar my-agent--height-small (my-agent--theme-height 'my-theme-font-size-s 90)
  "Height for metadata, labels and previews.")
(defvar my-agent--height-medium (my-agent--theme-height 'my-theme-font-size-m 120)
  "Height for prose, headings and code.")

(defface my-agent-heading '((t (:inherit font-lock-function-name-face :weight bold)))
  "Section titles." :group 'my-agent)
(defface my-agent-muted '((t (:inherit my-agent-meta))) "Secondary information." :group 'my-agent)
(defface my-agent-warning '((t (:inherit warning :weight bold))) "Attention." :group 'my-agent)
(defface my-agent-meta
  `((t (:inherit variable-pitch-text :height ,my-agent--height-small
            :foreground ,my-agent--color-muted)))
  "Labels, metadata and placeholders." :group 'my-agent)
(defface my-agent-you-label '((t (:inherit my-agent-meta :weight bold)))
  "Label above the human's own turns." :group 'my-agent)
(defface my-agent-think
  `((t (:inherit variable-pitch :height ,my-agent--height-small
            :foreground ,my-agent--color-muted)))
  "Marker of a thinking section." :group 'my-agent)
(defface my-agent-tool-name
  `((t (:inherit fixed-pitch :foreground ,my-agent--color-primary)))
  "Tool name in a card heading." :group 'my-agent)
(defface my-agent-tool-target
  `((t (:inherit fixed-pitch :foreground ,my-agent--color-foreground)))
  "Tool target in a card heading." :group 'my-agent)
(defface my-agent-tool-meta
  `((t (:inherit fixed-pitch :height ,my-agent--height-small
            :foreground ,my-agent--color-muted)))
  "Tool metadata in a card heading." :group 'my-agent)
(defface my-agent-tool-ok
  `((t (:inherit fixed-pitch :foreground ,my-agent--color-primary)))
  "Successful tool status." :group 'my-agent)
(defface my-agent-tool-error
  `((t (:inherit fixed-pitch :foreground ,my-agent--color-secondary)))
  "Failed tool status." :group 'my-agent)
(defface my-agent-tool-running
  `((t (:inherit fixed-pitch :foreground ,my-agent--color-muted)))
  "Running or approximate tool status." :group 'my-agent)
(defface my-agent-separator
  `((t (:inherit fixed-pitch :foreground ,my-agent--color-overlay)))
  "Thin rule that separates the transcript from the composer." :group 'my-agent)
(defface my-agent-output
  `((t (:inherit fixed-pitch :height ,my-agent--height-small
            :foreground ,my-agent--color-muted)))
  "Command output inside a tool card." :group 'my-agent)
(defface my-agent-attention
  `((t (:inherit variable-pitch-text :weight bold :foreground ,my-agent--color-primary)))
  "Pending question." :group 'my-agent)
(defface my-agent-event-info
  `((t (:inherit fixed-pitch :foreground ,my-agent--color-muted)))
  "Informational event." :group 'my-agent)
(defface my-agent-event-warn
  `((t (:inherit fixed-pitch :foreground ,my-agent--color-primary)))
  "Warning event." :group 'my-agent)
(defface my-agent-event-error
  `((t (:inherit fixed-pitch :foreground ,my-agent--color-secondary)))
  "Error event." :group 'my-agent)

(cl-defstruct (my-agent--session (:constructor my-agent--make-session))
  process stderr server peer runtime token directory log-directory cli-process seen cache-previous
  (counter 0) (serial 0) pending adapter-pending blocks blocks-tail index
  incoming backlog timer prompt output current-assistant current-assistant-key state stats metrics
  statuses commands dialogs history (history-index -1) history-draft attachments submissions
  (phase "starting") ready stopped attention capabilities fallbacks
  ;; Presentation state: the event plane, the composer and pending cards.
  (events 0) (event-errors 0) event-records events-buffer compose-timer compose-overlay chips
  cards stats-buffer stats-timer)
(cl-defstruct (my-agent--block (:constructor my-agent--make-block))
  id kind title (text "") chunks raw arguments collapsed start end body-end rendered
  streaming result overlay dirty
  ;; A block is a heading line and an optional body.  Keeping the two apart
  ;; lets a status change repaint the heading without touching the body.
  heading-start heading-end body-start status meta target note options)
(defvar-local my-agent--session nil "All mutable interaction state for this buffer.")
(defvar-local my-agent--prompt-cache nil "Last prompt text and its isolated Markdown presentation.")
(defvar-local my-agent--events-for nil "Session that owns this events buffer.")

(defun my-agent--object (&rest pairs)
  "Make a JSON object from alternating PAIRS."
  (let ((table (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) table)) table))
(defun my-agent--get (object key &optional default)
  "Read KEY from JSON OBJECT, returning DEFAULT for a non-object."
  (if (hash-table-p object) (gethash key object default) default))
(defun my-agent--array (value)
  "Return a list for JSON array VALUE."
  (cond ((vectorp value) (append value nil)) ((listp value) value)))
(defun my-agent--true (value) (eq value t))
(defun my-agent--json (value)
  "Encode VALUE without conflating JSON false and null."
  (let ((encoded (json-serialize value :null-object :null :false-object :false)))
    ;; Emacs's native serializer returns unibyte UTF-8, not Lisp characters.
    ;; Decode before buffer insertion or the process coding system would see
    ;; raw-eight-bit characters (and pretty-print them as octal escapes).
    (if (multibyte-string-p encoded) encoded (decode-coding-string encoded 'utf-8-unix))))
(defun my-agent--parse (text)
  (json-parse-string text :object-type 'hash-table :array-type 'array
                     :null-object :null :false-object :false))
(defun my-agent--pretty (value)
  (condition-case nil
      (with-temp-buffer (insert (my-agent--json value))
                        (json-pretty-print-buffer) (buffer-string))
    (error (format "%S" value))))
(defun my-agent--owned (buffer session function &rest args)
  "Call FUNCTION with ARGS only in BUFFER if SESSION still owns it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq my-agent--session session) (apply function args)))))
(defun my-agent--alive-p ()
  (and my-agent--session
       (process-live-p (my-agent--session-process my-agent--session))))
(defun my-agent--require-live ()
  (unless (my-agent--alive-p) (user-error "Agent is not running; use my-agent-restart")))
(defun my-agent--idle ()
  (my-agent--require-live)
  (unless (equal (my-agent--session-phase my-agent--session) "idle")
    (user-error "Wait until this agent settles, or abort it first")))

(defvar my-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (dolist (binding '(("C-c C-c" . my-agent-send) ("C-c C-s" . my-agent-steer)
                       ("C-c C-f" . my-agent-follow-up) ("C-c C-k" . my-agent-abort)
                       ("C-c C-d" . my-agent-answer) ("C-c C-p" . my-agent-menu)
                       ("C-c C-o" . my-agent-toggle-all) ("C-c C-r" . my-agent-resume)
                       ("C-c C-a" . my-agent-attach) ("C-c C-l" . my-agent-logs)
                       ("C-c C-e" . my-agent-events) ("C-c C-s" . my-agent-stats)
                       ("M-p" . my-agent-history-previous) ("M-n" . my-agent-history-next)
                       ("TAB" . my-agent-tab) ("C-c C-j" . my-agent-prompt)
                       ("RET" . my-agent-return) ("C-c C-v" . my-agent-visit)))
      (keymap-set map (car binding) (cdr binding))) map))

(define-derived-mode my-agent-mode text-mode "Pi"
  "One isolated Pi transcript with an editable prompt at the bottom."
  (my-agent--setup-font-lock)
  (setq-local buffer-face-mode-face 'variable-pitch)
  (buffer-face-mode 1)
  (setq-local header-line-format '(:eval (my-agent--header)))
  (setq-local mode-line-format
              '((:eval (my-agent--mode-line)) "  %l:%c"))
  (setq-local completion-at-point-functions '(my-agent--completion))
  (setq-local revert-buffer-function (lambda (&rest _) (my-agent-refresh)))
  (setq-local buffer-undo-list nil)
  (setq-local buffer-invisibility-spec '((my-agent . t)))
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
  (add-hook 'kill-buffer-query-functions #'my-agent--kill-query nil t)
  (add-hook 'kill-buffer-hook #'my-agent--cleanup nil t))

(defun my-agent--setup-font-lock ()
  "Keep global font-lock from stripping renderer-owned transcript faces."
  (setq-local font-lock-defaults '(nil t)
              font-lock-fontify-region-function #'my-agent--fontify-prompt
              font-lock-unfontify-region-function #'my-agent--unfontify-prompt)
  (font-lock-mode 1))

(defun my-agent--fontify-prompt (begin end &optional verbose)
  "Schedule the composer rendering; the transcript owns its own faces.
Live Markdown must not make typing expensive, so the draft is rendered once
the user stops typing instead of once per keystroke."
  (ignore begin end verbose)
  (when my-agent--session (my-agent--schedule-composer)))

(defun my-agent--unfontify-prompt (begin end)
  "Do not clear composer faces; the renderer replaces them atomically."
  (ignore begin end))

(defun my-agent--composer-start ()
  "Return the position where the editable composer starts."
  (if my-agent--session
      (marker-position (my-agent--session-prompt my-agent--session))
    (point-min)))

(defun my-agent--composer-text ()
  "Return the current composer text."
  (buffer-substring-no-properties (my-agent--composer-start) (point-max)))

(defun my-agent--apply-faces (start rendered)
  "Apply the FACE properties of RENDERED to the buffer from START."
  (with-silent-modifications
    (let ((offset 0)
          (length (length rendered)))
      (while (< offset length)
        (let* ((next (next-single-property-change offset 'face rendered length))
               (face (get-text-property offset 'face rendered))
               (faces (cond ((null face) nil)
                             ((listp face) face)
                             (t (list face)))))
          (when faces
            (put-text-property (+ start offset) (+ start next) 'face faces))
          (setq offset next))))))

(defun my-agent--composer-rule ()
  "Return the thin rule that separates the transcript from the composer."
  (make-string (max 0 my-agent-composer-rule-width) ?─))

(defun my-agent--render-composer ()
  "Render the composer: live Markdown faces and the placeholder."
  (when my-agent--session
    (let* ((start (my-agent--composer-start))
           (text (buffer-substring-no-properties start (point-max)))
           (rendered (if (equal text (car my-agent--prompt-cache))
                         (cdr my-agent--prompt-cache)
                       (let ((styled (my-agent--markdown text t)))
                         (setq my-agent--prompt-cache (cons text styled)) styled))))
      (with-silent-modifications
        (remove-text-properties start (point-max) '(face) nil))
      (my-agent--apply-faces start rendered))
    (my-agent--refresh-composer-overlay)))

(defun my-agent--schedule-composer ()
  "Render the composer once the draft stopped changing."
  (let ((session my-agent--session) (owner (current-buffer)))
    (when (timerp (my-agent--session-compose-timer session))
      (cancel-timer (my-agent--session-compose-timer session)))
    (setf (my-agent--session-compose-timer session)
          (run-at-time my-agent-compose-delay nil
                       #'my-agent--owned owner session #'my-agent--render-composer))))

(defun my-agent--refresh-composer-overlay ()
  "Show the placeholder while the composer is empty."
  (let* ((session my-agent--session)
         (overlay (my-agent--session-compose-overlay session))
         (start (my-agent--composer-start))
         (empty (string-empty-p (buffer-substring-no-properties start (point-max)))))
    (when (and overlay (overlay-buffer overlay)) (delete-overlay overlay))
    (setf (my-agent--session-compose-overlay session) nil)
    (when empty
      (let ((new (make-overlay start start nil nil t)))
        (overlay-put new 'overlay-string my-agent-composer-placeholder)
        (overlay-put new 'face 'my-agent-meta)
        (overlay-put new 'evaporate t)
        (overlay-put new 'priority 100)
        (overlay-put new 'insertion-type t)
        (setf (my-agent--session-compose-overlay session) new)))))

(defun my-agent--refresh-composer ()
  "Refresh every surface of the composer: tint, placeholder and chips."
  (when my-agent--session
    (my-agent--refresh-chips)
    (my-agent--render-composer)))

(defun my-agent--refresh-chips ()
  "Show the pending attachments as chips above the composer."
  (let* ((session my-agent--session)
         (overlay (my-agent--session-chips session))
         (attachments (my-agent--session-attachments session))
         (start (my-agent--composer-start)))
    (when (and overlay (overlay-buffer overlay)) (delete-overlay overlay))
    (setf (my-agent--session-chips session) nil)
    (when attachments
      (let* ((label (mapconcat
                     (lambda (attachment)
                       (concat "+ " (or (my-agent--get attachment "file") "attachment")))
                     attachments "   "))
             (new (make-overlay start start nil nil t)))
        (overlay-put new 'overlay-string (concat label "\n"))
        (overlay-put new 'face 'my-agent-meta)
        (overlay-put new 'priority 90)
        (overlay-put new 'insertion-type t)
        (setf (my-agent--session-chips session) new)))))

(defun my-agent-redraw (&optional expand-tools)
  "Reapply presentation without changing this agent's process or draft.
With prefix EXPAND-TOOLS, also expand existing tools. Use after loading an
updated my-agent.el into a running daemon; ordinary redraw preserves folds."
  (interactive "P")
  (unless (and (derived-mode-p 'my-agent-mode) my-agent--session)
    (user-error "Not an initialized Pi agent buffer"))
  (my-agent--setup-font-lock)
  (setq my-agent--prompt-cache nil)
  (dolist (block (my-agent--session-blocks my-agent--session))
    (when (eq (my-agent--block-kind block) 'tool)
      (when expand-tools (setf (my-agent--block-collapsed block) nil))
      (let* ((raw (my-agent--block-raw block))
             (result (cond ((equal (my-agent--get raw "role") "toolResult") raw)
                           ((member (my-agent--get raw "type") '("tool_execution_start" "tool_execution_update" "tool_execution_end"))
                            (or (my-agent--get raw "result") (my-agent--get raw "partialResult"))))))
        (when result (my-agent--update-tool-card block result))))
    (setf (my-agent--block-dirty block) t))
  (font-lock-flush (my-agent--session-prompt my-agent--session) (point-max))
  (my-agent--fontify-prompt (my-agent--session-prompt my-agent--session) (point-max))
  (my-agent--schedule))

(defmacro my-agent--output-edit (&rest body)
  "Perform BODY without altering prompt undo, modified status or user point."
  (declare (indent 0) (debug t))
  `(let ((modified (buffer-modified-p))
         (old-prompt (marker-position (my-agent--session-prompt my-agent--session))))
     (unwind-protect
         (let ((inhibit-read-only t) (buffer-undo-list t))
           (save-excursion ,@body))
       ;; Output before the prompt shifts absolute positions in Emacs's undo
       ;; entries. Rebase in place, preserving pending-undo-list tail identity.
       (let ((delta (- (marker-position (my-agent--session-prompt my-agent--session)) old-prompt))
             (tail buffer-undo-list))
         (unless (zerop delta)
           (while (consp tail)
             (setcar tail (undo-adjust-elt (car tail) (list (cons 0 (- delta)))))
             (setq tail (cdr tail)))))
       (set-buffer-modified-p modified))))

(defun my-agent--initialize ()
  "Initialize a fresh buffer-local session and protected prompt boundary."
  (setq my-agent--session
        (my-agent--make-session
         :pending (make-hash-table :test #'equal)
         :adapter-pending (make-hash-table :test #'equal)
         :index (make-hash-table :test #'equal)
         :statuses (make-hash-table :test #'equal)
         :state (my-agent--object)
         :seen (make-hash-table :test #'equal)
         :fallbacks (make-hash-table :test #'equal)))
  (let ((inhibit-read-only t))
    (erase-buffer)
    ;; The transcript grows downwards from the output marker; the composer is
    ;; always the last region of the buffer.  The blank line keeps the two
    ;; surfaces apart and gives the marker a stable anchor, the thin rule
    ;; marks where the input starts without filling a surface.
    (insert (propertize "\n" 'read-only t 'rear-nonsticky t))
    (insert (propertize (my-agent--composer-rule) 'face 'my-agent-separator
                         'read-only t 'rear-nonsticky t))
    (insert (propertize "\n" 'read-only t 'rear-nonsticky t))
    (setf (my-agent--session-output my-agent--session) (copy-marker (point-min) t)
          (my-agent--session-prompt my-agent--session) (copy-marker (point-max) nil)))
  (set-buffer-modified-p nil)
  (my-agent--refresh-composer))

(defun my-agent--draft ()
  (buffer-substring-no-properties (my-agent--session-prompt my-agent--session) (point-max)))
(defun my-agent--set-draft (text &optional append)
  "Set prompt TEXT; APPEND preserves an already composed draft."
  (let ((start (my-agent--session-prompt my-agent--session)))
    (save-excursion
      (goto-char start)
      (if append (goto-char (point-max)) (delete-region start (point-max)))
      (when (and append (> (point) start)) (insert "\n\n"))
      (insert text))
    (my-agent--schedule-composer)))
(defun my-agent-prompt ()
  "Move to the editable prompt."
  (interactive) (goto-char (point-max)))

(defun my-agent--block (id kind title &optional collapsed)
  "Find or append a block with ID, KIND, TITLE and initial COLLAPSED state."
  (let* ((session my-agent--session)
         (table (my-agent--session-index session))
         (block (gethash id table)))
    (unless block
      (setq block (my-agent--make-block :id id :kind kind :title title
                                        :collapsed collapsed :dirty t))
      (puthash id block table)
      (let ((cell (list block)))
        (if (my-agent--session-blocks-tail session)
            (setcdr (my-agent--session-blocks-tail session) cell)
          (setf (my-agent--session-blocks session) cell))
        (setf (my-agent--session-blocks-tail session) cell)))
    block))
(defun my-agent--notice (title data &optional warning collapsed)
  "Record TITLE and complete DATA in the event log, optionally WARNING.
System noise never enters the transcript: it is collected in the events
buffer and counted in the status line.  COLLAPSED is kept for callers that
used to place notices in the transcript."
  (ignore collapsed)
  (my-agent--log-event title data (if warning "warn" "info")))

(defun my-agent--events-buffer (&optional create)
  "Return the events buffer of this agent; create it when CREATE is non-nil.
The events buffer is a native compilation buffer: file and line references
inside events stay navigable with the standard compilation commands."
  (let* ((session my-agent--session)
         (buffer (my-agent--session-events-buffer session)))
    (or buffer
        (when create
          (let ((name (format "*Pi events · %s*"
                              (string-trim (buffer-name) "*"))))
            (setq buffer (get-buffer-create name))
            (with-current-buffer buffer
              (setq-local major-mode 'compilation-mode)
              (compilation-mode)
              (setq-local compilation-error-regexp-alist
                           '(("^\\([^ \t\n:]+\\):\\([0-9]+\\):" 1 2)))
              (setq-local compilation-scroll-output t)
              (setq-local my-agent--events-for session)
              (keymap-local-set "RET" #'my-agent--event-inspect)
              (keymap-local-set "g" #'my-agent--event-inspect))
            (setf (my-agent--session-events-buffer session) buffer)
            buffer)))))

(defun my-agent--event-inspect ()
  "Show the complete record of the event at point."
  (interactive)
  (let* ((index (get-text-property (point) 'my-agent-event))
         (session (and (boundp 'my-agent--events-for) my-agent--events-for)))
    (unless (and session index)
      (user-error "No event at point"))
    (let ((record (my-agent--event-record index session)))
      (with-current-buffer (generate-new-buffer "*Pi event*")
        (insert (my-agent--pretty record))
        (special-mode))
      (display-buffer (get-buffer "*Pi event*")))))

(defun my-agent--log-event (title data &optional severity)
  "Append TITLE and DATA to the events buffer of this agent.
SEVERITY is \"info\", \"warn\" or \"error\".  The complete record stays
retrievable, so nothing is lost by keeping it out of the transcript."
  (let* ((session my-agent--session)
         (severity (or severity "info"))
         (face (pcase severity
                 ("error" 'my-agent-event-error)
                 ("warn" 'my-agent-event-warn)
                 (_ 'my-agent-event-info)))
         (records (my-agent--session-event-records session))
         (buffer (my-agent--events-buffer t)))
    (push (cons title data) records)
    (setf (my-agent--session-event-records session) records
          (my-agent--session-events session) (1+ (my-agent--session-events session)))
    (when (equal severity "error")
      (setf (my-agent--session-event-errors session)
            (1+ (my-agent--session-event-errors session))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (propertize (format "%s  %-5s %s\n" (format-time-string "%H:%M:%S") severity title)
                               'face face
                               'my-agent-event (length records)))
          (when (and data (not (and (stringp data) (string-empty-p data))))
            (insert (propertize (if (stringp data) data (my-agent--pretty data))
                                 'face 'my-agent-event-info))
            (insert "\n"))
          (goto-char (point-max))
          (my-agent--trim-events))))
    (force-mode-line-update)
    title))

(defun my-agent--trim-events ()
  "Keep the events buffer within my-agent-event-limit lines."
  (let ((limit (max 100 my-agent-event-limit)))
    (when (> (line-number-at-pos (point-max)) limit)
      (goto-char (point-min))
      (forward-line (- (line-number-at-pos (point-max)) limit))
      (let ((inhibit-read-only t))
        (delete-region (point-min) (point))
        (insert "… earlier events dropped\n")))))

(defun my-agent--event-record (index &optional session)
  "Return the raw record with INDEX in the event log of SESSION."
  (let* ((session (or session my-agent--session))
         (records (my-agent--session-event-records session)))
    (when (and (integerp index) (>= index 0) (< index (length records)))
      (cdr (nth index records)))))
(defun my-agent--body-string (block)
  (when (my-agent--block-chunks block)
    (setf (my-agent--block-text block)
          (concat (my-agent--block-text block)
                  (apply #'concat (nreverse (my-agent--block-chunks block))))
          (my-agent--block-chunks block) nil))
  (my-agent--block-text block))
(defun my-agent--set-block (block text raw &optional title)
  (setf (my-agent--block-text block) text (my-agent--block-chunks block) nil
        (my-agent--block-raw block) raw (my-agent--block-dirty block) t)
  (when title (setf (my-agent--block-title block) title))
  block)

(defun my-agent--set-block-body (block text raw &optional title)
  "Set BLOCK's body TEXT/RAW without discarding an already executed result.
The final assistant message repeats tool calls without their results; replacing
the body there would erase the executed output and diff."
  (if (and (my-agent--block-result block)
           (not (equal text (my-agent--block-text block))))
      (progn
        (setf (my-agent--block-raw block) raw)
        (when title (setf (my-agent--block-title block) title)))
    (my-agent--set-block block text raw title)))

(defun my-agent--markdown (text &optional editing)
  "Fontify isolated Markdown TEXT, falling back to plain text.
EDITING keeps markup visible; callers editing a prompt copy only faces."
  (if (and (require 'markdown-ts-mode nil t)
           (treesit-language-available-p 'markdown)
           (treesit-language-available-p 'markdown-inline))
      (with-temp-buffer
        (insert text)
        ;; Do not run user text/prog hooks (Eglot, spellcheck, environments) here.
        (let ((text-mode-hook nil) (prog-mode-hook nil)
              (markdown-ts-mode-hook nil) (markdown-ts-view-mode-hook nil)
              (after-change-major-mode-hook nil)
              (change-major-mode-after-body-hook nil)
              (enable-local-variables nil))
          (markdown-ts-view-mode))
        (setq-local markdown-ts-inline-images nil)
        (when editing (setq-local markdown-ts-hide-markup nil))
        (font-lock-ensure)
        ;; Font-lock properties are portable; parser/overlay objects are not.
        (let ((result (buffer-string)))
          ;; Markdown uses overlays for the code-block base face. Append that
          ;; base underneath syntax faces so code keeps its monospace family
          ;; and background without losing language-specific foregrounds.
          (dolist (overlay (overlays-in (point-min) (point-max)))
            (when-let* ((face (overlay-get overlay 'face)))
              (add-face-text-property
               (- (max (point-min) (overlay-start overlay)) (point-min))
               (- (min (point-max) (overlay-end overlay)) (point-min))
               face t result)))
          (let ((position 0))
            (while (< position (length result))
              (let ((end (next-single-property-change position 'invisible result (length result))))
                (when (get-text-property position 'invisible result)
                  (put-text-property position end 'display "" result))
                (setq position end))))
          (remove-text-properties 0 (length result)
                                  '(read-only nil keymap nil modification-hooks nil
					      invisible nil fontified nil) result)
          result))
    text))
(defun my-agent--inspect (block)
  "Show full original BLOCK data in a private, independent inspector."
  (let ((buffer (generate-new-buffer "*Pi data*")))
    (with-current-buffer buffer
      (insert (my-agent--pretty (or (my-agent--block-raw block)
                                    (my-agent--body-string block))))
      (special-mode))
    (display-buffer buffer)))

(defun my-agent-inspect-at-point ()
  "Inspect the complete record of the block at point."
  (interactive)
  (if-let* ((block (get-text-property (point) 'my-agent-block)))
      (my-agent--inspect block)
    (user-error "No agent record at point")))

(defun my-agent-return ()
  "Inspect the record at point, or insert a newline inside the composer."
  (interactive)
  (if (>= (point) (my-agent--composer-start))
      (newline)
    (my-agent-inspect-at-point)))

(defun my-agent-events ()
  "Show the event log of this agent."
  (interactive)
  (display-buffer (my-agent--events-buffer t)))

(defun my-agent-stats ()
  "Show the state, statistics and metrics of this agent."
  (interactive)
  (let* ((session my-agent--session)
         (buffer (or (my-agent--session-stats-buffer session)
                     (get-buffer-create (format "*Pi stats · %s*" (buffer-name))))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "state\n")
        (insert (my-agent--pretty (my-agent--session-state session)))
        (insert "\n\nstatistics\n")
        (insert (my-agent--pretty (my-agent--session-stats session)))
        (insert "\n\nmetrics\n")
        (insert (my-agent--pretty (my-agent--session-metrics session)))
        (insert "\n\nevents\n")
        (insert (format "%d events · %d errors"
                        (my-agent--session-events session)
                        (my-agent--session-event-errors session))))
      (special-mode))
    (setf (my-agent--session-stats-buffer session) buffer)
    (display-buffer buffer)))
(defun my-agent--block-plain-p (block)
  "Return non-nil when BLOCK's body is rendered without Markdown parsing."
  (or (my-agent--block-streaming block)
      (not (memq (my-agent--block-kind block) '(assistant user thinking)))))

(defun my-agent--block-fixed-p (block)
  "Return non-nil when BLOCK's body uses the monospace face.
Tools, code, diffs and notices are fixed-pitch.  Prose keeps the buffer's
variable-pitch face, also while it streams, so text does not switch fonts
when the authoritative Markdown message replaces the deltas."
  (memq (my-agent--block-kind block) '(tool notice warning attention)))

(defun my-agent--body-face (block)
  "Return the face of the body of BLOCK.
Command output is quiet: it is muted and one size smaller than the text
around it, while the card heading keeps the normal emphasis."
  (if (equal (my-agent--block-title block) "bash") 'my-agent-output 'fixed-pitch))

(defun my-agent--insert-segments (segments)
  "Insert SEGMENTS, a list of (TEXT . FACE) pairs."
  (dolist (segment segments)
    (insert (propertize (car segment) 'face (cdr segment)))))

(defun my-agent--status-face (block)
  "Return the face describing the status glyph of BLOCK."
  (cond ((equal (my-agent--block-status block) "-") 'my-agent-tool-error)
        ((equal (my-agent--block-status block) "+") 'my-agent-tool-ok)
        (t 'my-agent-tool-running)))

(defun my-agent--tool-heading (block)
  "Return the heading SEGMENTS of a tool card."
  (let ((name (my-agent--block-title block))
        (target (my-agent--block-target block))
        (note (my-agent--block-note block))
        (status (my-agent--block-status block))
        (meta (my-agent--block-meta block)))
    (append
     (when name (list (cons name 'my-agent-tool-name)))
     (when (and name target) (list (cons "  " nil)))
     (when target (list (cons target 'my-agent-tool-target)))
     (when (and target note) (list (cons "  " nil)))
     (when note (list (cons note 'my-agent-tool-target)))
     (when status (list (cons "  " nil) (cons status (my-agent--status-face block))))
     (when meta (list (cons " " nil)
                      (cons (string-join (mapcar #'identity meta) " ") 'my-agent-tool-meta))))))

(defun my-agent--foldable-p (block)
  "Return non-nil when BLOCK has a body that can be folded."
  (eq (my-agent--block-kind block) 'tool))

(defun my-agent--block-body-p (block)
  "Return non-nil when BLOCK renders a body below its heading.
Thinking is one muted line: its text is the heading and there is nothing
to expand."
  (not (eq (my-agent--block-kind block) 'thinking)))

(defun my-agent--heading-segments (block)
  "Return the heading SEGMENTS of BLOCK as a list of (TEXT . FACE) pairs."
  (pcase (my-agent--block-kind block)
    ('assistant nil)
    ('user (list (cons "YOU" 'my-agent-you-label)))
    ('thinking (list (cons "thinking" 'my-agent-think)))
    ('attention (list (cons (my-agent--block-title block) 'my-agent-attention)))
    (_ (my-agent--tool-heading block))))

(defun my-agent--append-block (block text)
  "Append only the new tail of TEXT to an already rendered streaming BLOCK.
Only an append-only update is handled here; any other change forces a full
re-render, so a corrected stream cannot leave stale text behind."
  (let* ((rendered (my-agent--block-rendered block))
         (start (length rendered))
         (tail (and (> (length text) start)
                    (string-prefix-p rendered text)
                    (substring text start))))
    (when (and tail (my-agent--block-body-end block))
      (my-agent--output-edit
       (goto-char (my-agent--block-body-end block))
       (let ((inserted (point)))
         (insert tail)
         (when (my-agent--block-fixed-p block)
           (add-face-text-property inserted (point) 'fixed-pitch t))
         (set-marker (my-agent--block-body-end block) (point))
         (setf (my-agent--block-end block) (copy-marker (point) nil))))
      (setf (my-agent--block-rendered block) text)
      t)))

(defun my-agent--render-block (block)
  "Render only BLOCK, preserving other blocks, prompt and user view.
A block is a heading line and an optional body.  The heading carries the
identity of the block (tool, thinking, question); the body carries the
content.  Streaming bodies are appended in place; authoritative bodies are
re-rendered."
  (let ((text (my-agent--body-string block))
        (owner (current-buffer)) (session my-agent--session))
    (if (and (my-agent--block-body-p block)
             (my-agent--block-streaming block)
             (my-agent--block-body-end block)
             (my-agent--append-block block text))
        nil
      (my-agent--output-edit
       (if (my-agent--block-start block)
           (progn
             (goto-char (my-agent--block-start block))
             (delete-region (my-agent--block-start block) (my-agent--block-end block)))
         (goto-char (my-agent--session-output session))
         (setf (my-agent--block-start block) (copy-marker (point) t)))
       (when (my-agent--block-overlay block) (delete-overlay (my-agent--block-overlay block)))
       (let ((start (point)))
         (when (my-agent--heading-segments block)
           (let ((heading-start (point)))
             (when (my-agent--foldable-p block)
               (insert-text-button (if (my-agent--block-collapsed block) "▸ " "▾ ")
                                   'face 'my-agent-tool-meta 'follow-link t
                                   'action (lambda (_) (my-agent--owned owner session #'my-agent--toggle block))))
             (my-agent--insert-segments (my-agent--heading-segments block))
             (let ((heading-end (point)))
               (insert "\n")
               (setf (my-agent--block-heading-start block) (copy-marker heading-start t)
                     (my-agent--block-heading-end block) (copy-marker heading-end nil)))))
         (let ((body-start (point)))
           (when (my-agent--block-body-p block)
             (insert (if (my-agent--block-plain-p block)
                         (let ((literal (ansi-color-apply text)))
                           (when (my-agent--block-fixed-p block)
                             (add-face-text-property 0 (length literal) (my-agent--body-face block) t literal))
                           literal)
                       (condition-case err (my-agent--markdown text)
                         (error (concat "[Markdown rendering failed: " (error-message-string err) "]\n" text)))))
             (my-agent--insert-images (my-agent--block-raw block))
             (unless (bolp) (insert "\n")))
           (setf (my-agent--block-body-start block) (copy-marker body-start t))
           (when (and (my-agent--block-body-p block) (my-agent--block-options block))
             (add-text-properties body-start (point)
                                  (list 'keymap (my-agent--card-map block))))
           (let ((overlay (make-overlay body-start (point))))
             (overlay-put overlay 'invisible (when (my-agent--block-collapsed block) 'my-agent))
             (overlay-put overlay 'isearch-open-invisible
                          (lambda (_) (my-agent--owned owner session #'my-agent--expand block)))
             (setf (my-agent--block-overlay block) overlay))
           ;; The append point is the end of the body, before the separator.
           (let ((body-end (point)))
             (insert "\n")
             (add-text-properties start (point)
                                  (list 'read-only t 'rear-nonsticky t 'my-agent-block block))
             (set-marker (my-agent--block-start block) start)
             (setf (my-agent--block-end block) (copy-marker (point) nil)
                   (my-agent--block-body-end block) (copy-marker body-end nil)
                   (my-agent--block-rendered block) text)
             (my-agent--linkify start (point))))
         (setf (my-agent--block-dirty block) nil))))))
(defun my-agent--expand (block)
  (setf (my-agent--block-collapsed block) nil (my-agent--block-dirty block) t)
  (my-agent--render-block block))
(defun my-agent--toggle (block)
  (setf (my-agent--block-collapsed block) (not (my-agent--block-collapsed block))
        (my-agent--block-dirty block) t)
  (my-agent--render-block block))
(defun my-agent-tab ()
  "Toggle the section at point, or complete the prompt."
  (interactive)
  (if (>= (point) (my-agent--session-prompt my-agent--session))
      (completion-at-point)
    (when-let* ((block (get-text-property (point) 'my-agent-block))) (my-agent--toggle block))))
(defun my-agent-toggle-all ()
  "Expand all tool/thinking sections; collapse them if all are already open."
  (interactive)
  (let* ((blocks (cl-remove-if-not
                  (lambda (b) (memq (my-agent--block-kind b) '(tool thinking)))
                  (my-agent--session-blocks my-agent--session)))
         (collapse (not (cl-some #'my-agent--block-collapsed blocks))))
    (dolist (block blocks)
      (setf (my-agent--block-collapsed block) collapse (my-agent--block-dirty block) t))
    (my-agent--schedule)))

(defun my-agent--linkify (start end)
  "Make explicit URLs and existing file:line locations actionable in START END."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "https?://[^][ \t\n<>]+" end t)
      (let ((url (match-string-no-properties 0)))
        (make-text-button (match-beginning 0) (match-end 0) 'follow-link t
                          'action (lambda (_) (browse-url url)))))
    (goto-char start)
    (while (re-search-forward
            (rx (group (+ (not (any " \t\n`():"))))
                ":" (group (+ digit)) (optional ":" (group (+ digit)))) end t)
      (let ((file (expand-file-name (match-string-no-properties 1) default-directory))
            (line (string-to-number (match-string-no-properties 2)))
            (column (string-to-number (or (match-string-no-properties 3) "1"))))
        (when (file-regular-p file)
          (make-text-button (match-beginning 1) (match-end 0) 'follow-link t
                            'action (lambda (_)
                                      (find-file-other-window file)
                                      (goto-char (point-min)) (forward-line (1- line))
                                      (move-to-column (max 0 (1- column))))))))))
(defun my-agent-visit ()
  "Visit a button or file path at point without evaluating its contents."
  (interactive)
  (if-let* ((button (button-at (point)))) (button-activate button)
    (let* ((path (thing-at-point 'filename t))
           (file (and path (expand-file-name path default-directory))))
      (unless (and file (file-exists-p file)) (user-error "No existing file at point"))
      (find-file-other-window file))))

(defun my-agent--log (channel chunk)
  "Retain received CHUNK from CHANNEL before interpretation."
  (let* ((session my-agent--session) (directory (my-agent--session-log-directory session)))
    (condition-case err
        (when directory
          (let ((coding-system-for-write 'utf-8-unix)
                (write-region-inhibit-fsync t))
            (write-region chunk nil (expand-file-name (concat channel ".log") directory) t 'silent)))
      (error
       (let* ((table (my-agent--session-fallbacks session))
              (buffer (gethash channel table)))
         (unless (buffer-live-p buffer)
           (setq buffer (generate-new-buffer (format " *Pi retained %s*" channel)))
           (puthash channel buffer table)
           (my-agent--notice "Log write failed; retaining output in a private buffer"
                             (error-message-string err) t))
         (with-current-buffer buffer (goto-char (point-max)) (insert chunk)))))))
(defun my-agent--enqueue (source record)
  (push (cons source record) (my-agent--session-incoming my-agent--session))
  (my-agent--schedule))
(defun my-agent--filter (owner session channel process chunk)
  "Frame LF-only records for PROCESS; never prompt or render in a filter."
  (my-agent--owned
   owner session
   (lambda ()
     (my-agent--log channel chunk)
     (if (equal channel "stderr")
         (my-agent--enqueue 'stderr chunk)
       (let ((fragment (concat (or (process-get process 'fragment) "") chunk)) end)
         (while (setq end (string-search "\n" fragment))
           (let ((line (string-remove-suffix "\r" (substring fragment 0 end))))
             (setq fragment (substring fragment (1+ end)))
             (condition-case nil
                 (let ((record (my-agent--parse line)))
                   (unless (hash-table-p record) (error "Expected object"))
                   (if (equal channel "adapter")
                       (my-agent--enqueue 'adapter (cons process record))
                     (my-agent--enqueue 'rpc record)))
               (error (my-agent--enqueue 'malformed (cons channel line))))))
         (process-put process 'fragment fragment))))))
(defun my-agent--schedule ()
  (let ((session my-agent--session) (owner (current-buffer)))
    (unless (timerp (my-agent--session-timer session))
      (setf (my-agent--session-timer session)
            (run-at-time 0.03 nil #'my-agent--owned owner session #'my-agent--flush)))))
(defun my-agent--flush ()
  "Reduce a bounded batch, then redisplay dirty blocks, without modal input."
  (let ((session my-agent--session) (limit 200))
    (when (timerp (my-agent--session-timer session)) (cancel-timer (my-agent--session-timer session)))
    (setf (my-agent--session-timer session) nil)
    (unless (my-agent--session-backlog session)
      (setf (my-agent--session-backlog session) (nreverse (my-agent--session-incoming session))
            (my-agent--session-incoming session) nil))
    (while (and (> limit 0) (my-agent--session-backlog session))
      (cl-decf limit)
      (pcase-let ((`(,source . ,record) (pop (my-agent--session-backlog session))))
        (condition-case err
            (pcase source
              ('rpc (my-agent--event record))
              ('adapter (my-agent--adapter-event (cdr record) (car record)))
              ('stderr (my-agent--notice "Pi diagnostic (stderr)" record t))
              ('malformed (my-agent--notice (format "Malformed %s output" (car record)) (cdr record) t))
              ('exit
               (setf (my-agent--session-phase session) "stopped")
               (my-agent--fail-pending record)
               (my-agent--notice "Pi process exited" record t)))
          (error (my-agent--notice "Frontend handler failed; complete record follows"
                                   (my-agent--object "error" (error-message-string err) "record" record) t)))))
    (dolist (block (my-agent--session-blocks session))
      (when (my-agent--block-dirty block)
        (condition-case err (my-agent--render-block block)
          (error
           (setf (my-agent--block-kind block) 'warning
                 (my-agent--block-text block)
                 (concat "[Presentation failed: " (error-message-string err) "]\n" (my-agent--body-string block)))
           ;; Plain rendering is independent of the failing Markdown path.
           (my-agent--render-block block)))))
    (force-mode-line-update)
    (when (or (my-agent--session-backlog session) (my-agent--session-incoming session))
      (my-agent--schedule))))

(defun my-agent--write (process record channel)
  (unless (process-live-p process) (user-error "Transport is disconnected"))
  (let ((line (concat (my-agent--json record) "\n")))
    (my-agent--log channel line)
    (process-send-string process line)))
(defun my-agent--rpc (type &optional data callback)
  "Send TYPE/DATA with a buffer-local request ID and CALLBACK."
  (my-agent--require-live)
  (let* ((session my-agent--session)
         (id (format "r%d" (cl-incf (my-agent--session-counter session))))
         (record (or data (my-agent--object))))
    (puthash "id" id record) (puthash "type" type record)
    (puthash id (cons type callback) (my-agent--session-pending session))
    (condition-case err
        (my-agent--write (my-agent--session-process session) record "commands")
      (error (remhash id (my-agent--session-pending session)) (signal (car err) (cdr err))))
    id))
(defun my-agent--query (type &optional data)
  "User-initiated synchronous TYPE query; filters remain asynchronous."
  (let ((done nil) answer failure
        (deadline (+ (float-time) my-agent-request-timeout)))
    (let ((id (my-agent--rpc type data
			     (lambda (record)
			       (setq done t answer (my-agent--get record "data")
				     failure (unless (my-agent--true (my-agent--get record "success"))
					       (my-agent--get record "error" "Command failed")))))))
      (while (and (not done) (my-agent--alive-p) (< (float-time) deadline))
	(accept-process-output nil 0.03))
      (while (and (not done) (or (my-agent--session-incoming my-agent--session)
				 (my-agent--session-backlog my-agent--session)))
	(my-agent--flush))
      (unless done
	(remhash id (my-agent--session-pending my-agent--session))
	(user-error "Pi query timed out; a later response will be shown as unmatched"))
      (when failure (user-error "%s" failure)) answer)))
(defun my-agent--fail-pending (reason)
  "Fail unresolved commands on exit, restoring unaccepted input through callbacks."
  (let ((session my-agent--session) pending)
    (maphash (lambda (id entry) (push (cons id entry) pending)) (my-agent--session-pending session))
    (clrhash (my-agent--session-pending session))
    (dolist (item pending)
      (when-let* ((callback (cddr item)))
        (condition-case err
            (funcall callback (my-agent--object "type" "response" "id" (car item)
						"success" :false "error" (concat "Pi exited: " reason)))
          (error (my-agent--notice "Exit callback failed" (error-message-string err) t)))))
    (setq pending nil)
    (maphash (lambda (id callback) (push (cons id callback) pending)) (my-agent--session-adapter-pending session))
    (clrhash (my-agent--session-adapter-pending session))
    (dolist (item pending)
      (funcall (cdr item) (my-agent--object "type" "failure" "id" (car item)
                                            "data" (my-agent--object "message" (concat "Pi exited: " reason)))))))

(defun my-agent--response (record)
  (let* ((table (my-agent--session-pending my-agent--session))
         (id (my-agent--get record "id")) (entry (gethash id table)))
    (remhash id table)
    (unless (my-agent--true (my-agent--get record "success"))
      (my-agent--notice "Pi command failed" record t))
    (cond ((cdr entry) (funcall (cdr entry) record))
          ((not entry) (my-agent--notice "Unmatched Pi response" record t))
          ((my-agent--get record "data")
           (my-agent--notice (format "Pi response · %s" (car entry)) record nil t)))))

(defun my-agent--insert-images (record)
  "Insert only image bytes already received in RECORD; never fetch URLs."
  (when (display-images-p)
    (let* ((message (or (my-agent--get record "message") record))
           (result (or (my-agent--get message "result") (my-agent--get message "partialResult") message)))
      (dolist (item (my-agent--array (my-agent--get result "content")))
        (when (equal (my-agent--get item "type") "image")
          (condition-case err
              (let* ((bytes (base64-decode-string (my-agent--get item "data" "")))
                     (image (create-image bytes nil t :max-width 800 :max-height 600)))
                (when image (insert "\n") (insert-image image) (insert "\n")))
            (error (insert (format "\n[Image display failed: %s; bytes retained in data]\n" (error-message-string err))))))))))

(defun my-agent--code (text mode)
  "Fontify literal TEXT in built-in MODE without running user/project hooks."
  (with-temp-buffer
    (insert text)
    (let ((prog-mode-hook nil) (text-mode-hook nil) (sh-mode-hook nil)
          (diff-mode-hook nil) (after-change-major-mode-hook nil)
          (change-major-mode-after-body-hook nil) (enable-local-variables nil)
          (inhibit-message t) (message-log-max nil))
      (funcall mode))
    (font-lock-ensure)
    (let ((result (buffer-string)))
      (remove-text-properties 0 (length result)
                              '(read-only nil keymap nil display nil invisible nil
                                          modification-hooks nil fontified nil) result)
      (add-face-text-property 0 (length result) 'fixed-pitch t result)
      result)))

(defun my-agent--section (title)
  "Return a fixed-pitch tool subsection TITLE."
  (propertize title 'face '(my-agent-heading fixed-pitch)))

(defun my-agent--fields-text (object &optional skip)
  "Show OBJECT fields without JSON-escaping multiline string values.
SKIP contains fields already presented natively, never unknown fields.
Keys are sorted: hash order is unspecified and must not reorder the display."
  (if (not (hash-table-p object)) (my-agent--pretty object)
    (let (parts)
      (dolist (key (sort (copy-sequence (my-agent--object-keys object)) #'string<))
        (unless (member key skip)
          (let ((value (gethash key object)))
            (push (concat (my-agent--section (concat key ":"))
                          (if (and (stringp value) (string-search "\n" value)) "\n" " ")
                          (if (stringp value) value (my-agent--pretty value))) parts))))
      (string-join (nreverse parts) "\n\n"))))

(defun my-agent--object-keys (object)
  "Return OBJECT's keys as a list of strings."
  (let (keys)
    (maphash (lambda (key _value) (push (format "%s" key) keys)) object)
    (nreverse keys)))

(defun my-agent--replacement (edit)
  "Present known EDIT replacement text as a readable, highlighted diff."
  (let ((old (my-agent--get edit "oldText")) (new (my-agent--get edit "newText")))
    (if (not (and (stringp old) (stringp new))) (my-agent--fields-text edit)
      (concat
       (my-agent--code
        (concat (mapconcat (lambda (line) (concat "-" line)) (split-string old "\n") "\n")
                "\n" (mapconcat (lambda (line) (concat "+" line)) (split-string new "\n") "\n") "\n")
        #'diff-mode)
       (let ((extra (my-agent--fields-text edit '("oldText" "newText"))))
         (unless (string-empty-p extra) (concat "\n" extra)))))))

(defun my-agent--tool-arguments (name args &optional has-patch)
  "Present ARGS as commands/files/replacements, not escaped protocol JSON.
The name of the tool is NAME.  HAS-PATCH avoids repeating edit replacement
bodies when a result diff exists; original arguments remain in the section's
data inspector and raw log."
  (when (hash-table-p args)
    (let ((command (my-agent--get args "command"))
          (path (my-agent--get args "path"))
          (edits (my-agent--get args "edits")) skip parts)
      ;; The heading of a shell card carries the whole command already.
      (when (stringp command)
        (push "command" skip)
        (unless (equal name "bash")
          (push (concat (my-agent--section "Command") "\n$ " (my-agent--code command #'sh-mode)) parts)))
      (when (stringp path)
        (push "path" skip)
        (push (concat (my-agent--section "File: ") path) parts))
      (when (or (vectorp edits) (consp edits))
        (push "edits" skip)
        (push (format "%d replacement%s" (length edits) (if (= (length edits) 1) "" "s")) parts)
        (unless has-patch
          (dolist (edit (my-agent--array edits)) (push (my-agent--replacement edit) parts)))
        ;; Additional fields in edit entries must not vanish just because the
        ;; known old/new strings are represented by an authoritative patch.
        (when has-patch
          (dolist (edit (my-agent--array edits))
            (let ((extra (my-agent--fields-text edit '("oldText" "newText"))))
              (unless (string-empty-p extra) (push extra parts))))))
      (let ((extra (my-agent--fields-text args skip)))
        (unless (string-empty-p extra) (push extra parts)))
      (string-join (nreverse parts) "\n\n"))))

(defun my-agent--tool-text (name args result)
  "Present complete RESULT with native commands, output and one readable diff.
Known patch/diff strings are presented once rather than duplicated as escaped
JSON. Unknown arguments/details remain visible; the full record is in [data]."
  (let* ((details (my-agent--get result "details"))
         (unified (my-agent--get details "patch"))
         (diff (my-agent--get details "diff"))
         (patch (if (stringp unified) unified (when (stringp diff) diff)))
         (output (my-agent--content-text (my-agent--get result "content")))
         (arguments (my-agent--tool-arguments name args (and patch t)))
         (line (my-agent--get details "firstChangedLine"))
         (skip (append (when (stringp unified) '("patch"))
                       (when (stringp diff) '("diff"))
                       (when (numberp line) '("firstChangedLine"))))
         (extra (when (and details (not (eq details :null)))
                  (my-agent--fields-text details skip))))
    (string-join
     (delq nil
           (list (unless (or (null arguments) (string-empty-p arguments)) arguments)
                 (unless (string-empty-p output) (concat (my-agent--section "Output") "\n" output))
                 (when patch (concat (my-agent--section "Diff") "\n" (my-agent--code patch #'diff-mode)))
                 (when (numberp line) (format "First changed line: %s" line))
                 (unless (or (null extra) (string-empty-p extra))
                   (concat (my-agent--section "Additional result data") "\n" extra))))
     "\n\n")))

(defun my-agent--tool-target (_name args)
  "Return the target of the tool with ARGS.
The command of a shell tool is shown whole: the heading wraps instead of
truncating, so nothing of the executed command is lost."
  (let ((path (my-agent--get args "path"))
        (pattern (my-agent--get args "pattern"))
        (command (my-agent--get args "command")))
    (cond
     ((and (stringp path) (stringp pattern))
      (format "%s  %s" pattern path))
     ((stringp path) path)
     ((stringp pattern) (concat "\"" pattern "\""))
     ((stringp command) command)
     (t ""))))

(defun my-agent--read-range (args result)
  "Return the line range of a read call as \"FIRST-LAST\" or \"FIRST-LAST of TOTAL\"."
  (let* ((content (my-agent--content-text (my-agent--get result "content")))
         (notice (and (string-match "\\[Showing lines \\([0-9]+\\)-\\([0-9]+\\) of \\([0-9]+\\)" content)
                       (list (match-string 1 content) (match-string 2 content) (match-string 3 content))))
         (offset (or (my-agent--get args "offset") 1))
         ;; Trailing notices are not part of the returned content.
         (body (replace-regexp-in-string "\\n*\\[[^][]*\\][[:space:]]*$" "" content))
         (returned (max 1 (length (split-string body "\n")))))
    (if notice
        (format "%s-%s of %s" (nth 0 notice) (nth 1 notice) (nth 2 notice))
      (format "%s-%s" offset (+ offset (1- returned))))))

(defun my-agent--tool-note (name args result)
  "Return the extra NOTE shown next to the target of the tool NAME."
  (pcase name
    ("read" (my-agent--read-range args result))
    ((or "edit" "write")
     (let* ((details (my-agent--get result "details"))
            (unified (my-agent--get details "patch"))
            (diff (my-agent--get details "diff"))
            (patch (if (stringp unified) unified (when (stringp diff) diff)))
            (counters (and patch (my-agent--patch-counters patch))))
       (when (and counters (or (> (car counters) 0) (> (cadr counters) 0)))
         (format "+%d -%d" (car counters) (cadr counters)))))
    (_ nil)))

(defun my-agent--tool-status (block _result)
  "Return the status glyph of the tool card BLOCK."
  (let ((errorp (or (my-agent--true (my-agent--get (my-agent--block-raw block) "isError"))
                    (and (stringp (my-agent--block-title block))
                         (string-match-p "ERROR" (my-agent--block-title block))))))
    (cond (errorp "-")
          ((my-agent--block-result block) "+")
          (t "~"))))

(defun my-agent--tool-duration (block)
  "Return the duration of the tool card BLOCK as a short string."
  (let ((milliseconds (my-agent--get (my-agent--block-raw block) "durationMs")))
    (when (numberp milliseconds)
      (if (>= milliseconds 1000)
          (format "%.1fs" (/ milliseconds 1000.0))
        (format "%dms" (round milliseconds))))))

(defun my-agent--patch-counters (patch)
  "Return the added and removed line counts of PATCH."
  (let ((added 0) (removed 0))
    (when (stringp patch)
      (dolist (line (split-string patch "\n"))
        (cond ((string-prefix-p "---" line) nil)
              ((string-prefix-p "+++" line) nil)
              ((string-prefix-p "+" line) (setq added (1+ added)))
              ((string-prefix-p "-" line) (setq removed (1+ removed))))))
    (list added removed)))

(defun my-agent--tool-meta (block _result)
  "Return the metadata strings of the tool card BLOCK."
  (let ((duration (my-agent--tool-duration block)))
    (when duration (list duration))))

(defun my-agent--tool-body (name args result)
  "Return the body text of the tool NAME with ARGS and RESULT."
  (let* ((details (my-agent--get result "details"))
         (unified (my-agent--get details "patch"))
         (diff (my-agent--get details "diff"))
         (patch (if (stringp unified) unified (when (stringp diff) diff)))
         (output (my-agent--content-text (my-agent--get result "content")))
         (truncation (my-agent--get details "truncation"))
         (full (my-agent--get details "fullOutputPath")))
    (pcase name
      ;; The file content is available in the file itself; the card only
      ;; states which lines were read.
      ("read" "")
      ("bash" (let ((text (replace-regexp-in-string "\\n*\\[Command exited with code [0-9]+\\]\\s*$" "" output)))
                (concat text
                        (when (my-agent--get truncation "truncated")
                          (format "\n[showing %s of %s lines · full output: %s]"
                                  (my-agent--get truncation "outputLines" "?")
                                  (my-agent--get truncation "totalLines" "?")
                                  (or full "unknown"))))))
      ("edit" (if patch (my-agent--code patch #'diff-mode) output))
      ("write" (let* ((content (my-agent--get args "content"))
                      (lines (and (stringp content) (split-string content "\n"))))
                  (when (and lines (string-empty-p (car (last lines))))
                    (setq lines (butlast lines)))
                  (if (null lines) output
                    (concat (string-join (mapcar (lambda (line) (concat "+ " line))
                                                 (cl-subseq lines 0 (min (length lines) 200)))
                                         "\n")
                            (when (> (length lines) 200)
                              (format "\n… %d more lines" (- (length lines) 200)))))))
      ((or "grep" "find" "ls") output)
      (_ (my-agent--tool-text name args result)))))

(defun my-agent--update-tool-card (block result)
  "Recompute heading and body of the tool card BLOCK with RESULT."
  (let* ((raw (my-agent--block-raw block))
         (name (or (my-agent--get raw "toolName")
                   (and (stringp (my-agent--block-title block)) (my-agent--block-title block))
                   "tool"))
         (args (my-agent--block-arguments block)))
    (setf (my-agent--block-title block) name
          (my-agent--block-target block) (my-agent--tool-target name args)
          (my-agent--block-note block) (my-agent--tool-note name args result)
          (my-agent--block-status block) (my-agent--tool-status block result)
          (my-agent--block-meta block) (my-agent--tool-meta block result)
          ;; A later update without a result (the final message repeats the
          ;; call) must not erase the body that was already executed.
          (my-agent--block-text block) (cond (result (my-agent--tool-body name args result))
                                              ((my-agent--block-result block) (my-agent--block-text block))
                                              (t (my-agent--tool-arguments name args))))
    block))

(defun my-agent--content-text (content)
  "Plain representation of arbitrary CONTENT; unknown content is not discarded."
  (if (stringp content) content
    (mapconcat
     (lambda (item)
       (pcase (my-agent--get item "type")
         ("text" (my-agent--get item "text" ""))
         ("thinking" (my-agent--get item "thinking" ""))
         ("image" (format "[image · %s · expand data to inspect bytes]" (my-agent--get item "mimeType")))
         (_ (concat "[Additional/unknown content]\n" (my-agent--pretty item)))))
     (my-agent--array content) "\n")))
(defun my-agent--tool (id &optional name)
  (my-agent--block (concat "tool:" (or id "unknown")) 'tool (or name "tool") nil))
(defun my-agent--message (message &optional final)
  "Display MESSAGE, using FINAL authoritative values when present."
  (let* ((role (my-agent--get message "role"))
         (content (my-agent--get message "content"))
         (key (format "message:%s:%s:%s" role (my-agent--get message "timestamp")
                      (my-agent--get message "toolCallId"))))
    (pcase role
      ("assistant"
       ;; A new assistant message starts a new group of blocks.  Streaming
       ;; deltas adopt the group that is already open.
       (when (and (my-agent--session-current-assistant my-agent--session)
                  (my-agent--session-current-assistant-key my-agent--session)
                  (not (equal key (my-agent--session-current-assistant-key my-agent--session))))
         (setf (my-agent--session-current-assistant my-agent--session) nil))
       (unless (my-agent--session-current-assistant my-agent--session)
         (setf (my-agent--session-current-assistant my-agent--session)
               (or (gethash key (my-agent--session-seen my-agent--session))
                   (format "assistant:%d" (cl-incf (my-agent--session-serial my-agent--session))))))
       (setf (my-agent--session-current-assistant-key my-agent--session) key)
       (puthash key (my-agent--session-current-assistant my-agent--session)
                (my-agent--session-seen my-agent--session))
       (let ((prefix (my-agent--session-current-assistant my-agent--session)) (i 0))
         (dolist (item (my-agent--array content))
           (let* ((type (my-agent--get item "type"))
                  (kind (pcase type ("text" 'assistant) ("thinking" 'thinking) ("toolCall" 'tool) (_ 'warning)))
                  (block (if (equal type "toolCall")
                             (my-agent--tool (my-agent--get item "id") (my-agent--get item "name"))
                           (my-agent--block (format "%s:%d" prefix i) kind
                                            (pcase kind ('assistant "Pi") ('thinking "Thinking") (_ "Unrecognized Pi content"))
                                            nil))))
             (when (equal type "toolCall")
               (setf (my-agent--block-arguments block) (my-agent--get item "arguments")
                     (my-agent--block-raw block) message)
               (my-agent--update-tool-card block nil)
               (setf (my-agent--block-dirty block) t))
             ;; An authoritative message ends the speculative stream: render the
             ;; final text as Markdown instead of the streaming plain body.
             (when (member type '("text" "thinking"))
               (setf (my-agent--block-streaming block) nil))
             (unless (equal type "toolCall")
               (my-agent--set-block-body block
                                         (pcase type
                                          ("text" (my-agent--get item "text" ""))
                                          ("thinking" (my-agent--get item "thinking" "[redacted/unavailable]"))
                                          (_ (my-agent--pretty item)))
                                         message))
             (cl-incf i))))
       (when (my-agent--get message "errorMessage")
         (my-agent--notice "Assistant error" message t))
       (when final (setf (my-agent--session-current-assistant my-agent--session) nil)))
      ("toolResult"
       (let ((block (my-agent--tool (my-agent--get message "toolCallId") (my-agent--get message "toolName"))))
         (setf (my-agent--block-result block) t
               (my-agent--block-raw block) message)
         (my-agent--update-tool-card block message)
         (setf (my-agent--block-dirty block) t)))
      ("user"
       (let ((block (my-agent--block key 'user "YOU")))
         (my-agent--set-block block (my-agent--content-text content) message)
         (setf (my-agent--block-dirty block) t)))
      (_
       ;; Everything that is not a human turn belongs to the event plane.
       (my-agent--log-event
        (pcase role ("bashExecution" "Shell") ("system" "System prompt / tools")
                    ("custom" "Extension message") ("compactionSummary" "Compaction summary")
                    ("branchSummary" "Branch summary")
                    (_ (format "Unrecognized message role · %s" role)))
        (cond (content (my-agent--content-text content))
              ((my-agent--get message "output") (my-agent--get message "output"))
              ((my-agent--get message "summary") (my-agent--get message "summary"))
              (t (my-agent--pretty message)))
        (if (member role '("system" "custom" "compactionSummary" "branchSummary" "bashExecution"))
            "info"
          "warn"))))))
(defun my-agent--delta (record)
  (let* ((event (my-agent--get record "assistantMessageEvent"))
         (type (my-agent--get event "type"))
         (index (my-agent--get event "contentIndex" 0))
         (session my-agent--session))
    (unless (my-agent--session-current-assistant session)
      (setf (my-agent--session-current-assistant session)
            (format "assistant:%d" (cl-incf (my-agent--session-serial session)))))
    (let* ((key (format "%s:%d" (my-agent--session-current-assistant session) index))
           (kind (cond ((string-prefix-p "thinking" (or type "")) 'thinking)
                       ((string-prefix-p "toolcall" (or type "")) 'tool) (t 'assistant)))
           (block (my-agent--block key kind
                                   (pcase kind ('thinking "Thinking · streaming") ('tool "Tool arguments · streaming") (_ "Pi · streaming"))
                                   nil)))
      (setf (my-agent--block-raw block) record
            (my-agent--block-streaming block) t)
      (cond ((member type '("text_delta" "thinking_delta" "toolcall_delta"))
             (push (my-agent--get event "delta" "") (my-agent--block-chunks block))
             ;; A thinking section is a static marker: its text is kept in the
             ;; record, not rendered, so deltas must not trigger a redraw.
             (unless (eq kind 'thinking)
               (setf (my-agent--block-dirty block) t)))
            ((member type '("text_end" "thinking_end"))
             (my-agent--set-block block (my-agent--get event "content" "") record)
             (setf (my-agent--block-streaming block) nil))
            ((equal type "toolcall_start")
             (let ((id (my-agent--get event "id")))
               (when id
                 (puthash (concat "tool:" id) block (my-agent--session-index session))))
             (setf (my-agent--block-title block) (my-agent--get event "toolName" "tool")
                   (my-agent--block-dirty block) t))
            ((equal type "toolcall_end")
             (let* ((call (my-agent--get event "toolCall")) (id (my-agent--get call "id")))
               (when id (puthash (concat "tool:" id) block (my-agent--session-index session)))
               (setf (my-agent--block-arguments block) (my-agent--get call "arguments")
                     (my-agent--block-raw block) record)
               (my-agent--update-tool-card block nil)
               (setf (my-agent--block-streaming block) nil
                     (my-agent--block-dirty block) t)))
            ((member type '("text_start" "thinking_start" "start")) nil)
            ((member type '("done" "error")) (my-agent--notice "Provider stream outcome" record (equal type "error")))
            (t (my-agent--notice "Unrecognized streaming update" record t))))))

(defun my-agent--usage-notice (message)
  "Expose CLI-derived cache and provider diagnostic information from MESSAGE.
Cache notices are labelled estimates, not a claim about provider internals."
  (let* ((previous (my-agent--session-cache-previous my-agent--session))
         (usage (my-agent--get message "usage"))
         (prior (my-agent--get previous "usage"))
         (read (my-agent--get usage "cacheRead" 0))
         (write (my-agent--get usage "cacheWrite" 0))
         (input (my-agent--get usage "input" 0))
         (prompt (+ input read write))
         (prior-prompt (+ (my-agent--get prior "input" 0) (my-agent--get prior "cacheRead" 0) (my-agent--get prior "cacheWrite" 0)))
         (missed (- (min prior-prompt prompt) read)))
    (when (and previous (> missed 1024)
               (> (+ read write (my-agent--get prior "cacheRead" 0) (my-agent--get prior "cacheWrite" 0)) 0))
      (let* ((cost (my-agent--get usage "cost"))
             (paid (+ input write))
             (paid-rate (if (> paid 0) (/ (+ (my-agent--get cost "input" 0.0) (my-agent--get cost "cacheWrite" 0.0)) (float paid)) 0.0))
             (read-rate (if (> read 0) (/ (my-agent--get cost "cacheRead" 0.0) (float read)) 0.0))
             (extra (* missed (max 0.0 (- paid-rate read-rate)))))
        (when (or (>= missed 20000) (>= extra 0.1))
          (my-agent--notice "Cache rebilling estimate"
                            (format "%d tokens not reused · estimated extra cost $%.3f\nBased only on reported usage; full diagnostics in message data." missed extra) t))))
    (when (my-agent--get message "diagnostics")
      (my-agent--notice "Provider diagnostics" (my-agent--get message "diagnostics") nil t))
    (when (> prompt 0) (setf (my-agent--session-cache-previous my-agent--session) message))))

(defun my-agent--event (record)
  "Reduce every Pi RECORD; unknown variants always become visible."
  (let ((session my-agent--session) (type (my-agent--get record "type")))
    (pcase type
      ("response" (my-agent--response record))
      ("agent_start" (setf (my-agent--session-phase session) "working")
                   (my-agent--start-stats-poll))
      ("agent_settled"
       (setf (my-agent--session-phase session) "idle"
             (my-agent--session-submissions session) nil)
       (my-agent--stop-stats-poll)
       (my-agent--refresh-state))
      ("agent_end" (my-agent--notice "Agent run ended (may continue automatically)" record nil t))
      ("turn_start" (setf (my-agent--session-phase session) "thinking"))
      ("turn_end" (my-agent--notice "Turn completed" record nil t))
      ("message_start" (my-agent--message (my-agent--get record "message")))
      ("message_update" (my-agent--delta record))
      ("message_end"
       (let ((message (my-agent--get record "message")))
         (when (equal (my-agent--get message "role") "assistant") (my-agent--usage-notice message))
         (my-agent--message message t)))
      ((or "tool_execution_start" "tool_execution_update" "tool_execution_end")
       (let* ((block (my-agent--tool (my-agent--get record "toolCallId") (my-agent--get record "toolName")))
              (end (equal type "tool_execution_end"))
              (result (my-agent--get record (if end "result" "partialResult")))
              (errorp (my-agent--true (my-agent--get record "isError"))))
         (setf (my-agent--session-phase session) "tools")
         (when (my-agent--get record "args")
           (setf (my-agent--block-arguments block) (my-agent--get record "args")))
         (setf (my-agent--block-raw block) record)
         (when end (setf (my-agent--block-result block) t))
         (my-agent--update-tool-card block result)
         (setf (my-agent--block-dirty block) t)
         (when errorp (setf (my-agent--session-attention session) t))))
      ("bash_execution_update"
       (let ((block (my-agent--tool (my-agent--get record "id") "shell")))
         (push (my-agent--get record "delta" "") (my-agent--block-chunks block))
         (setf (my-agent--block-dirty block) t (my-agent--block-raw block) record)))
      ("extension_ui_request" (my-agent--ui record))
      ("queue_update"
       (puthash "queues" record (my-agent--session-statuses session))
       (my-agent--notice "Pending steering / follow-up queue" record nil t))
      ("session_info_changed" (puthash "sessionName" (my-agent--get record "name") (my-agent--session-state session)))
      ("thinking_level_changed" (puthash "thinkingLevel" (my-agent--get record "level") (my-agent--session-state session)))
      ("entry_appended"
       (let ((entry (my-agent--get record "entry")))
         (if (and (equal (my-agent--get entry "type") "usage")
                  (equal (my-agent--get entry "kind") "cache_warm"))
             (progn
               (setf (my-agent--session-cache-previous session)
                     (my-agent--object "usage" (my-agent--get entry "usage")))
               (my-agent--notice "Cache warming · billed usage" record nil t))
           (my-agent--notice "Session entry appended" record nil t))))
      ("compaction_start"
       (setf (my-agent--session-phase session) "compacting")
       (my-agent--notice "Compacting model context (transcript retained)" record))
      ("compaction_end"
       (setf (my-agent--session-cache-previous session) nil)
       (my-agent--notice "Compaction outcome / billed usage" record (and (my-agent--get record "errorMessage") t)))
      ((or "auto_retry_start" "auto_retry_end" "summarization_retry_scheduled"
           "summarization_retry_attempt_start" "summarization_retry_finished")
       (setf (my-agent--session-phase session) "retry/recovery")
       (my-agent--notice "Pi retry / recovery" record t))
      ("extension_error" (my-agent--notice "Pi extension error" record t))
      (_ (my-agent--notice (format "Unrecognized Pi output · %s" type) record t)))))

;; Adapter, dialogs and lifecycle ------------------------------------------------

(defun my-agent--extra-fields (data known id title)
  "Expose unimplemented fields in DATA beyond KNOWN under stable ID and TITLE."
  (when (hash-table-p data)
    (let ((extra (my-agent--object)))
      (maphash (lambda (key value) (unless (member key known) (puthash key value extra))) data)
      (when (> (hash-table-count extra) 0)
        (my-agent--set-block (my-agent--block id 'warning title)
                             (my-agent--pretty extra) data)))))

(defun my-agent--adapter-event (record &optional origin)
  (let* ((session my-agent--session) (type (my-agent--get record "type"))
         (data (my-agent--get record "data")) (peer (or origin (my-agent--session-peer session))))
    (cond
     ((not (eql (my-agent--get record "v") 1))
      (my-agent--notice "Unsupported adapter protocol" record t))
     ((equal type "hello")
      (if (and (equal (my-agent--get record "token") (my-agent--session-token session))
               (= (my-agent--get record "pid" -1)
                  (or (process-id (my-agent--session-process session)) -2)))
          (progn
            (process-put peer 'authenticated t)
            (setf (my-agent--session-peer session) peer
                  (my-agent--session-runtime session) (my-agent--get record "runtime"))
            (my-agent--write peer (my-agent--object "v" 1 "type" "hello" "token" (my-agent--session-token session)) "adapter-commands"))
        (my-agent--notice "Rejected unauthenticated adapter connection" "Unexpected token or PID" t)
        (delete-process peer)))
     ((not (and peer (process-get peer 'authenticated)))
      (my-agent--notice "Unauthenticated adapter output" record t))
     ((not (equal (my-agent--get record "runtime") (my-agent--session-runtime session)))
      (my-agent--notice "Stale adapter runtime output" record t))
     (t
      (pcase type
        ("ready"
         (setf (my-agent--session-capabilities session) (my-agent--array (my-agent--get data "capabilities")))
         (when-let* ((cwd (my-agent--get data "cwd")) ((stringp cwd)))
           (unless (equal (file-name-as-directory cwd) default-directory)
             (my-agent--notice "Workspace changed; process environment remains launch-scoped"
                               "For a different direnv environment, start a new agent from that project's source buffer." t))
           (setq default-directory (file-name-as-directory cwd)))
         (unless (my-agent--true (my-agent--get data "trusted"))
           (my-agent--notice "Project resources are not trusted" data t))
         (my-agent--notice "Adapter ready · capabilities and limitations" data nil t)
         (my-agent--refresh-state))
        ("trust"
         (my-agent--dialog 'trust record)
         (my-agent--notice "Project trust requires a decision · C-c C-d"
                           (concat (my-agent--get data "cwd" "")
                                   "\nTrust permits project settings, executable extensions, packages and MCP servers.\nDeclining does not sandbox tools or exclude AGENTS.md.") t))
        ("status"
         (my-agent--extra-fields data
                                 '("version" "sessionId" "snapshot" "observedAt" "activeMilliseconds"
                                   "promptMilliseconds" "tokensPerSecond" "provider" "windows"
                                   "toolCalls" "addedLines" "removedLines")
                                 "additional-status" "Additional unimplemented status data")
         (if (eql (my-agent--get data "version") 1)
             (setf (my-agent--session-metrics session)
                   (unless (eq (my-agent--get data "snapshot") :null) data))
           (my-agent--notice "Unrecognized status snapshot" record t)))
        ("notification"
         (my-agent--extra-fields data
                                 '("version" "id" "sessionId" "observedAt" "title" "body" "severity" "desktopDelivered")
                                 "additional-notification" "Additional unimplemented notification data")
         (my-agent--log-event (format "Notification · %s" (my-agent--get data "title" "Pi"))
                              (my-agent--get data "body" (my-agent--pretty data))
                              (if (member (my-agent--get data "severity") '("warning" "error"))
                                  "warn"
                                "info"))
         (unless (eql (my-agent--get data "version") 1)
           (my-agent--notice "Unrecognized notification protocol version" record t))
         (setf (my-agent--session-attention session) t)
         (when (and (eql (my-agent--get data "version") 1)
                    (not (my-agent--true (my-agent--get data "desktopDelivered"))))
           (when (require 'notifications nil t)
             (condition-case err
                 (notifications-notify :title (format "Pi · %s" (buffer-name))
                                       :body (my-agent--get data "body" "Done"))
               (error (my-agent--notice "Native notification fallback failed" (error-message-string err) t))))))
        ((or "result" "failure")
         (let* ((table (my-agent--session-adapter-pending session))
                (id (my-agent--get record "id")) (callback (gethash id table)))
           (remhash id table)
           (if callback (funcall callback record)
             (my-agent--notice "Unmatched adapter response" record t))
           (when (equal type "failure") (my-agent--notice "Adapter operation failed" record t))))
        (_ (my-agent--notice (format "Unrecognized adapter output · %s" type) record t)))))))

(defun my-agent--adapter-query (op &optional arguments)
  "User-initiated adapter OP through a fresh Pi extension command context."
  (unless (member op (my-agent--session-capabilities my-agent--session))
    (user-error "Adapter does not advertise %s; use native RPC or explicit CLI handoff" op))
  (let* ((session my-agent--session)
         (id (format "a%d" (cl-incf (my-agent--session-counter session))))
         (request (or arguments (my-agent--object)))
         (deadline (+ (float-time) my-agent-request-timeout)) done answer failure)
    (puthash "id" id request) (puthash "op" op request)
    (puthash id (lambda (record)
                  (setq done t answer (my-agent--get record "data")
                        failure (when (equal (my-agent--get record "type") "failure")
                                  (my-agent--get answer "message" "Adapter failed"))))
             (my-agent--session-adapter-pending session))
    (my-agent--rpc "prompt" (my-agent--object "message" (concat "/emacs-agent " (my-agent--json request)))
                   (lambda (record)
                     (unless (my-agent--true (my-agent--get record "success"))
                       (setq done t failure (my-agent--get record "error")))))
    (while (and (not done) (my-agent--alive-p) (< (float-time) deadline))
      (accept-process-output nil 0.03))
    (unless done
      (remhash id (my-agent--session-adapter-pending session))
      (user-error "Adapter query timed out; late results will be shown"))
    (when failure (user-error "%s" failure)) answer))

(defun my-agent--ui (record)
  (let* ((session my-agent--session) (method (my-agent--get record "method"))
         (statuses (my-agent--session-statuses session)))
    (pcase method
      ((or "select" "confirm" "input" "editor")
       (my-agent--dialog 'rpc record)
       (my-agent--notice "Pi needs input · C-c C-d" record t))
      ("notify"
       (my-agent--log-event "Pi notification" (my-agent--get record "message" "")
                            (if (member (my-agent--get record "notifyType") '("warning" "error"))
                                "warn"
                              "info")))
      ("setStatus"
       (puthash (my-agent--get record "statusKey") (my-agent--get record "statusText") statuses))
      ("setWidget"
       (my-agent--log-event (format "Widget · %s" (my-agent--get record "widgetKey"))
                            (mapconcat #'identity (my-agent--array (my-agent--get record "widgetLines")) "\n")
                            "info"))
      ("setTitle" (puthash "title" (my-agent--get record "title") statuses))
      ("set_editor_text"
       ;; Never overwrite a user's in-progress draft with an asynchronous update.
       (my-agent--set-draft (my-agent--get record "text" "") t)
       (my-agent--notice "Extension text appended to prompt (existing draft preserved)" record nil t))
      (_
       (my-agent--notice (format "Unsupported extension UI request · %s" method) record t)
       (my-agent--write (my-agent--session-process session)
                        (my-agent--object "type" "extension_ui_response" "id" (my-agent--get record "id") "cancelled" t)
                        "commands")))))
(defun my-agent--dialog (transport record)
  (let* ((session my-agent--session) (owner (current-buffer))
         (timeout (my-agent--get record "timeout"))
         (dialog (list transport record)))
    (setf (my-agent--session-dialogs session)
          (append (my-agent--session-dialogs session) (list dialog)))
    (my-agent--attention-card dialog)
    (when (numberp timeout)
      (run-at-time (/ timeout 1000.0) nil
                   #'my-agent--owned owner session
                   (lambda ()
                     (when (member dialog (my-agent--session-dialogs session))
                       (setf (my-agent--session-dialogs session)
                             (delq dialog (my-agent--session-dialogs session)))
                       (my-agent--expire-card dialog)
                       (my-agent--notice "Pi dialog expired (no consent given)" record t)))))))

(defconst my-agent--trust-options '("Allow once" "Remember allow" "Decline once" "Remember decline")
  "Choices offered when Pi asks for project trust.")

(defun my-agent--dialog-options (dialog)
  "Return the discrete OPTIONS of DIALOG, or nil when free text is needed."
  (let* ((transport (car dialog)) (record (cadr dialog))
         (method (my-agent--get record "method")))
    (pcase transport
      ('trust my-agent--trust-options)
      (_ (pcase method
           ("select" (my-agent--array (my-agent--get record "options")))
           ("confirm" '("Yes" "No"))
           (_ nil))))))

(defun my-agent--dialog-title (dialog)
  "Return the heading of the question in DIALOG."
  (let* ((transport (car dialog)) (record (cadr dialog))
         (method (my-agent--get record "method")))
    (pcase transport
      ('trust (format "Trust %s?" (my-agent--get (my-agent--get record "data") "cwd" "this project")))
      (_ (pcase method
           ("select" (format "%s" (my-agent--get record "title" "Pi")))
           ("confirm" (format "%s" (my-agent--get record "title" "Pi")))
           (_ (format "%s" (my-agent--get record "title" "Pi needs an answer"))))))))

(defun my-agent--dialog-body (dialog)
  "Return the body text of the question in DIALOG."
  (let* ((options (my-agent--dialog-options dialog))
         (record (cadr dialog))
         (message (my-agent--get record "message" "")))
    (concat
     (unless (string-empty-p message) (concat message "\n"))
     (if options
         (concat (let ((index 0))
                   (mapconcat (lambda (option)
                                (setq index (1+ index))
                                (format "[%d] %s" index option))
                              options "   "))
                 "\nAnswer with a number, or C-c C-d.")
       "Answer with C-c C-d."))))

(defun my-agent--attention-card (dialog)
  "Show the question in DIALOG as a card in the transcript."
  (let* ((session my-agent--session)
         (id (format "attention-%s" (cl-incf (my-agent--session-serial session))))
         (block (my-agent--block id 'attention (my-agent--dialog-title dialog))))
    (setf (my-agent--block-raw block) dialog
          (my-agent--block-options block) (my-agent--dialog-options dialog))
    (my-agent--set-block block (my-agent--dialog-body dialog) dialog)
    (push (cons block dialog) (my-agent--session-cards session))
    (setf (my-agent--session-attention session) t)
    (my-agent--schedule)
    block))

(defun my-agent--card-map (block)
  "Return a keymap answering the attention card BLOCK with a number."
  (let ((map (make-sparse-keymap)))
    (dotimes (index 9)
      (let ((choice (1+ index)))
        (keymap-set map (char-to-string (+ ?0 choice))
                    (lambda () (interactive) (my-agent--answer-choice block choice)))))
    map))

(defun my-agent--find-card (dialog)
  "Return the attention card that belongs to DIALOG."
  (let ((entry (cl-find-if (lambda (entry) (equal (cdr entry) dialog))
                           (my-agent--session-cards my-agent--session))))
    (and entry (car entry))))

(defun my-agent--expire-card (dialog)
  "Mark the card of DIALOG as expired."
  (when-let* ((block (my-agent--find-card dialog))
              (session my-agent--session))
    (setf (my-agent--session-cards session)
          (delq (assq block (my-agent--session-cards session))
                (my-agent--session-cards session))
          (my-agent--block-options block) nil)
    (my-agent--set-block block "expired — no answer given" dialog)
    (setf (my-agent--block-dirty block) t)))

(defun my-agent--resolve-card (dialog answer-text)
  "Mark the card of DIALOG as answered with ANSWER-TEXT."
  (when-let* ((block (my-agent--find-card dialog))
              (session my-agent--session))
    (setf (my-agent--session-cards session)
          (delq (assq block (my-agent--session-cards session))
                (my-agent--session-cards session))
          (my-agent--block-options block) nil)
    (my-agent--set-block block (concat "answered: " answer-text) dialog)
    (setf (my-agent--block-dirty block) t)))

(defun my-agent--answer-choice (block choice)
  "Answer the attention card BLOCK with the numbered CHOICE."
  (let* ((session my-agent--session)
         (entry (assq block (my-agent--session-cards session)))
         (options (my-agent--block-options block)))
    (unless entry (user-error "This question is no longer pending"))
    (unless (and options (<= 1 choice) (<= choice (length options)))
      (user-error "Choose a number between 1 and %s" (length options)))
    (let* ((dialog (cdr entry))
           (transport (car dialog))
           (record (cadr dialog))
           (text (nth (1- choice) options)))
      (my-agent--answer-dialog
       dialog
       (pcase transport
         ('trust (my-agent--object "trusted" (if (member text '("Allow once" "Remember allow")) t :false)
                                 "remember" (if (string-prefix-p "Remember" text) t :false)))
         (_ (pcase (my-agent--get record "method")
              ("select" (my-agent--object "value" text))
              ("confirm" (my-agent--object "confirmed" (equal text "Yes")))
              (_ (my-agent--object "cancelled" t)))))
       text))))

(defun my-agent--answer-dialog (dialog answer &optional answer-text)
  "Send ANSWER for DIALOG and record ANSWER-TEXT as the visible choice."
  (let ((session my-agent--session) (record (cadr dialog)))
    (unless (member dialog (my-agent--session-dialogs session))
      (user-error "This dialog has expired or already been answered"))
    (setf (my-agent--session-dialogs session) (delq dialog (my-agent--session-dialogs session)))
    (puthash "id" (my-agent--get record "id") answer)
    (if (eq (car dialog) 'trust)
        (progn (puthash "v" 1 answer) (puthash "type" "answer" answer)
               (my-agent--write (my-agent--session-peer session) answer "adapter-commands"))
      (puthash "type" "extension_ui_response" answer)
      (my-agent--write (my-agent--session-process session) answer "commands"))
    (my-agent--resolve-card dialog (or answer-text "answered"))
    (my-agent--notice "Dialog answered" (my-agent--get record "title" "Project trust") nil t)))
(defun my-agent-answer ()
  "Answer the oldest pending question in THIS agent, without stealing focus."
  (interactive)
  (let* ((session my-agent--session) (owner (current-buffer))
         (dialog (car (my-agent--session-dialogs session)))
         (record (cadr dialog)) (method (my-agent--get record "method"))
         (title (my-agent--get record "title" "Pi")))
    (unless dialog (user-error "No pending questions in this agent"))
    (catch 'my-agent-editor
      (condition-case nil
          (my-agent--answer-dialog
           dialog
           (if (eq (car dialog) 'trust)
               (let ((choice (completing-read
                              (format "Trust %s? " (my-agent--get (my-agent--get record "data") "cwd"))
                              my-agent--trust-options nil t nil nil "Decline once")))
		 (my-agent--object "trusted" (if (member choice '("Allow once" "Remember allow")) t :false)
                                   "remember" (if (string-prefix-p "Remember" choice) t :false)))
             (pcase method
               ("select" (my-agent--object "value" (completing-read (concat title ": ") (my-agent--array (my-agent--get record "options")) nil t)))
               ("confirm" (my-agent--object "confirmed" (if (yes-or-no-p (format "%s: %s " title (my-agent--get record "message" ""))) t :false)))
               ("input" (my-agent--object "value" (read-string (concat title ": ") nil nil (my-agent--get record "placeholder"))))
               ("editor"
		(let ((buffer (generate-new-buffer (format "*Pi editor · %s*" (buffer-name)))))
                  (with-current-buffer buffer
                    (text-mode)
                    (insert (my-agent--get record "prefill" ""))
                    (setq-local header-line-format "C-c C-c submit · C-c C-k cancel")
                    (keymap-local-set
                     "C-c C-c"
                     (lambda () (interactive)
                       (let ((value (buffer-string)))
			 (my-agent--owned owner session #'my-agent--answer-dialog dialog (my-agent--object "value" value)))
                       (kill-current-buffer)))
                    (keymap-local-set
                     "C-c C-k"
                     (lambda () (interactive)
                       (my-agent--owned owner session #'my-agent--answer-dialog dialog (my-agent--object "cancelled" t))
                       (kill-current-buffer))))
                  (pop-to-buffer buffer))
		(throw 'my-agent-editor nil))
               (_ (my-agent--object "cancelled" t)))))
	(quit (my-agent--owned owner session #'my-agent--answer-dialog dialog (my-agent--object "cancelled" t)))))))

(defun my-agent--refresh-stats ()
  "Refresh the session statistics that the header line shows."
  (when (my-agent--alive-p)
    (condition-case nil
        (my-agent--rpc "get_session_stats" nil
                       (lambda (record)
                         (when (my-agent--true (my-agent--get record "success"))
                           (setf (my-agent--session-stats my-agent--session)
                                 (my-agent--get record "data")))))
      (error nil))))

(defun my-agent--stats-poll ()
  "Poll the statistics while the agent works, then schedule the next poll."
  (let ((session my-agent--session) (owner (current-buffer)))
    (setf (my-agent--session-stats-timer session) nil)
    (when (and session (not (equal (my-agent--session-phase session) "idle")))
      (my-agent--refresh-stats)
      (setf (my-agent--session-stats-timer session)
            (run-at-time 2 nil
                         #'my-agent--owned owner session #'my-agent--stats-poll)))))

(defun my-agent--start-stats-poll ()
  "Start the statistics poll for a working agent."
  (let ((session my-agent--session) (owner (current-buffer)))
    (when (and session (not (timerp (my-agent--session-stats-timer session))))
      (setf (my-agent--session-stats-timer session)
            (run-at-time 2 nil #'my-agent--owned owner session #'my-agent--stats-poll)))))

(defun my-agent--stop-stats-poll ()
  "Stop the statistics poll of a settled agent."
  (when-let* ((session my-agent--session))
    (when (timerp (my-agent--session-stats-timer session))
      (cancel-timer (my-agent--session-stats-timer session))
      (setf (my-agent--session-stats-timer session) nil))))

(defun my-agent--refresh-state ()
  "Asynchronously refresh state/statistics/commands without querying per token."
  (when (my-agent--alive-p)
    (my-agent--rpc "get_state" nil
                   (lambda (record)
                     (when (my-agent--true (my-agent--get record "success"))
                       (let ((state (my-agent--get record "data")))
                         (setf (my-agent--session-state my-agent--session) state
                               (my-agent--session-ready my-agent--session) t)
                         (unless (or (my-agent--true (my-agent--get state "isStreaming"))
                                     (my-agent--true (my-agent--get state "isCompacting")))
                           (setf (my-agent--session-phase my-agent--session) "idle"))))))
    (my-agent--rpc "get_session_stats" nil
                   (lambda (record) (setf (my-agent--session-stats my-agent--session) (my-agent--get record "data"))))
    (my-agent--rpc "get_commands" nil
                   (lambda (record) (setf (my-agent--session-commands my-agent--session)
                                          (my-agent--array (my-agent--get (my-agent--get record "data") "commands")))))))
(defun my-agent-refresh ()
  "Refresh THIS agent's state and restore missing raw active-branch history."
  (interactive)
  (my-agent--idle)
  (let* ((data (my-agent--query "get_entries"))
         (entries (my-agent--array (my-agent--get data "entries")))
         (table (make-hash-table :test #'equal))
         (leaf (my-agent--get data "leafId")) path)
    (dolist (entry entries) (puthash (my-agent--get entry "id") entry table))
    (while (and (stringp leaf) (gethash leaf table))
      (let ((entry (gethash leaf table)))
        (push entry path) (remhash leaf table) (setq leaf (my-agent--get entry "parentId"))))
    (my-agent--notice "Active branch restored · previous transcript retained" "Raw entries include pre-compaction history; use /tree to inspect other branches." nil t)
    (dolist (entry path)
      (pcase (my-agent--get entry "type")
        ("message" (my-agent--message (my-agent--get entry "message") t))
        (_ (my-agent--notice (format "Saved entry · %s" (my-agent--get entry "type")) entry nil t))))
    (my-agent--refresh-state)
    (my-agent--schedule)))

(defun my-agent--duration (milliseconds)
  (let ((seconds (floor (/ (or milliseconds 0) 1000))))
    (if (< seconds 60) (format "%ss" seconds) (format "%sm%02ss" (/ seconds 60) (% seconds 60)))))
(defun my-agent--phase-face (phase)
  "Return the face describing the agent PHASE."
  (pcase phase
    ("idle" 'my-agent-meta)
    ("stopped" 'my-agent-tool-error)
    ("starting" 'my-agent-tool-running)
    ((or "working" "thinking" "tools" "compacting") 'my-agent-tool-name)
    (_ 'my-agent-tool-error)))

(defun my-agent--header ()
  "Render the live metrics of this agent in the header line.
Keep unexpected status schemas visible without breaking Emacs redisplay."
  (condition-case err (my-agent--header-string)
    (error (format "unsupported status data: %s" (error-message-string err)))))

(defun my-agent--join-parts (parts)
  "Join PARTS, a list of (TEXT . FACE) pairs, with a muted separator."
  (string-join (mapcar (lambda (part)
                          (propertize (car part) 'face (cdr part)))
                        (delq nil parts))
               (propertize " · " 'face 'my-agent-meta)))

(defun my-agent--join-shared (parts)
  "Join the shared PARTS the way Pi joins its own footer cells.
Pi separates the counters of its stats line with a single space; the
Emacs only cells keep the muted dot of this frontend."
  (string-join (mapcar (lambda (part)
                          (propertize (car part) 'face (cdr part)))
                        (delq nil parts))
               " "))

(defun my-agent--format-tokens (count)
  "Format COUNT the way Pi formats token counts."
  (cond ((not (numberp count)) "0")
        ((< count 1000) (number-to-string (truncate count)))
        ((< count 10000) (format "%.1fk" (/ count 1000.0)))
        ((< count 1000000) (format "%dk" (round (/ count 1000.0))))
        ((< count 10000000) (format "%.1fM" (/ count 1000000.0)))
        (t (format "%dM" (round (/ count 1000000.0))))))

(defun my-agent--context-face (percent)
  "Return the face of the context cell for PERCENT.
Pi turns the context share into an error above ninety percent and into a
warning above seventy percent."
  (cond ((not (numberp percent)) 'my-agent-meta)
        ((> percent 90) 'my-agent-tool-error)
        ((> percent 70) 'my-agent-warning)
        (t 'my-agent-tool-target)))

(defun my-agent--context-part (stats state)
  "Return the context usage cell of the header line.
Pi reports the used share of the context window; the window itself comes
from the model when the session does not report one."
  (let* ((context (my-agent--get stats "contextUsage"))
         (percent (my-agent--get context "percent"))
         (model (my-agent--get state "model"))
         (window (or (my-agent--get context "contextWindow")
                     (my-agent--get model "contextWindow"))))
    (when (numberp window)
      (cons (format "%s/%s"
                    (if (numberp percent) (format "%.1f%%" percent) "?")
                    (my-agent--format-tokens window))
            (my-agent--context-face percent)))))

(defun my-agent--header-string ()
  "Render the metrics that stay visible while the agent works.
The order follows Pi's own footer: tokens in, tokens out, cache reads,
cache writes, cost and context usage.  The remaining cells are Emacs
only and stay after the shared ones."
  (when-let* ((session my-agent--session))
    (let* ((stats (my-agent--session-stats session))
           (state (my-agent--session-state session))
           (tokens (my-agent--get stats "tokens"))
           (metrics (my-agent--session-metrics session))
           (windows (my-agent--array (my-agent--get metrics "windows")))
           (shared nil)
           (extra nil))
      (dolist (cell '(("↑" . "input") ("↓" . "output") ("R" . "cacheRead") ("W" . "cacheWrite")))
        (let ((value (my-agent--get tokens (cdr cell))))
          (when (and (numberp value) (> value 0))
            (push (cons (format "%s%s" (car cell) (my-agent--format-tokens value))
                        'my-agent-meta)
                  shared))))
      (let ((cost (my-agent--get stats "cost")))
        (when (and (numberp cost) (> cost 0))
          (push (cons (format "$%.3f" cost) 'my-agent-tool-target) shared)))
      (when-let* ((context (my-agent--context-part stats state)))
        (push context shared))
      (when (hash-table-p metrics)
        (push (cons (format "%s calls" (my-agent--get metrics "toolCalls" 0)) 'my-agent-meta) extra)
        (push (cons (format "+%s" (my-agent--get metrics "addedLines" 0)) 'my-agent-tool-ok) extra)
        (push (cons (format "-%s" (my-agent--get metrics "removedLines" 0)) 'my-agent-tool-error) extra))
      (dolist (window windows)
        (let* ((reset (- (* 1000 (my-agent--get window "resetAt" 0)) (* 1000 (float-time))))
               (stale (or (<= reset 0) (> (- (* 1000 (float-time)) (my-agent--get window "observedAt" 0)) 600000)))
               (remaining (if (<= reset 0) nil (- 100 (my-agent--get window "usedPercent" 0)))))
          (push (cons (format "%s%s%sm %s"
                               (if stale "~" "")
                               (my-agent--get window "windowMinutes")
                               (if (= (my-agent--get window "windowMinutes" 0) 300) "h" "w")
                               (if remaining (format "%d%%" (round remaining)) "?"))
                      (if (and remaining (< remaining 20)) 'my-agent-tool-error 'my-agent-meta))
                extra)))
      (when (> (my-agent--session-events session) 0)
        (push (cons (format "%d events" (my-agent--session-events session))
                    (if (> (my-agent--session-event-errors session) 0)
                        'my-agent-tool-error
                      'my-agent-meta))
              extra))
      (when (my-agent--session-dialogs session)
        (push (cons "answer needed" 'my-agent-warning) extra))
      (when-let* ((queues (gethash "queues" (my-agent--session-statuses session))))
        (let ((steering (length (my-agent--array (my-agent--get queues "steering"))))
              (follow-up (length (my-agent--array (my-agent--get queues "followUp")))))
          (when (> (+ steering follow-up) 0)
            (push (cons (format "queued %d/%d" steering follow-up) 'my-agent-meta) extra))))
      (let ((shared (my-agent--join-shared (nreverse shared)))
            (extra (my-agent--join-parts (nreverse extra))))
        (if (string-empty-p extra) shared (concat shared " · " extra))))))

(defun my-agent--mode-line ()
  "Render the identity of this agent in the mode line."
  (when my-agent--session
    (let* ((state (my-agent--session-state my-agent--session))
           (model (my-agent--get state "model"))
           (phase (my-agent--session-phase my-agent--session))
           (name (or (my-agent--get state "sessionName")
                     (file-name-nondirectory (directory-file-name default-directory)))))
      (my-agent--join-parts
       (list (cons name 'my-agent-tool-name)
             (cons (or (my-agent--get model "id") "no model") 'my-agent-tool-target)
             (cons (or (my-agent--get state "thinkingLevel") "–") 'my-agent-meta)
             (cons phase (my-agent--phase-face phase))
             (when (my-agent--session-attention my-agent--session)
               (cons "!" 'my-agent-tool-error)))))))

(defun my-agent--accept (owner session server client _message)
  "Bind a private socket CLIENT to its immutable owner, never selected-buffer."
  (unless (and (buffer-live-p owner) (eq (buffer-local-value 'my-agent--session owner) session))
    (delete-process client))
  (my-agent--owned
   owner session
   (lambda ()
     ;; Reload's new socket may connect before the old socket reaches EOF.
     ;; Authenticate each origin first; only hello may replace the active peer.
     (set-process-query-on-exit-flag client nil)
     (set-process-coding-system client 'utf-8-unix 'utf-8-unix)
     (set-process-filter client (lambda (proc chunk) (my-agent--filter owner session "adapter" proc chunk)))
     (set-process-sentinel client
                           (lambda (proc _event)
                             (unless (process-live-p proc)
                               (my-agent--owned owner session
                                                (lambda ()
                                                  (my-agent--finish-fragment proc "adapter")
                                                  (when (eq proc (my-agent--session-peer session))
                                                    (setf (my-agent--session-capabilities session) nil)
                                                    (my-agent--notice "Adapter disconnected" "RPC may continue. Reload reconnects the new runtime." t)))))))
     (process-put client 'server server))))
(defun my-agent--finish-fragment (process channel)
  (when-let* ((fragment (process-get process 'fragment)) ((not (string-empty-p fragment))))
    (process-put process 'fragment "")
    (condition-case nil
        (if (equal channel "adapter")
            (my-agent--enqueue 'adapter (cons process (my-agent--parse fragment)))
          (my-agent--enqueue 'rpc (my-agent--parse fragment)))
      (error (my-agent--notice (format "Incomplete %s record at EOF" channel) fragment t)))))
(defun my-agent--start (&optional session-file)
  "Start Pi and its private listener; SESSION-FILE resumes only this writer."
  (let* ((session my-agent--session) (owner (current-buffer))
         (process-environment (copy-sequence process-environment))
         (runtime-directory (make-temp-file "my-agent-" t))
         (socket (expand-file-name "bridge" runtime-directory))
         ;; Socket-directory permissions are the security boundary; this token
         ;; additionally detects cross-session/misrouted connections. Same-UID
         ;; arbitrary code already has Pi's privileges and is not sandboxed.
         (token (secure-hash 'sha256 (format "%s:%s:%s" (random t) (random) runtime-directory)))
         (log-base (file-name-as-directory (expand-file-name my-agent-log-directory)))
         (args (append (list "--mode" "rpc") my-agent-arguments
                       (when my-agent-adapter-file (list "--extension" my-agent-adapter-file))
                       (when session-file (list "--session" session-file)))))
    (set-file-modes runtime-directory #o700)
    (setf (my-agent--session-directory session) runtime-directory)
    (make-directory log-base t)
    (set-file-modes log-base #o700)
    (setf (my-agent--session-directory session) runtime-directory
          (my-agent--session-token session) token
          (my-agent--session-log-directory session) (make-temp-file (expand-file-name "session-" log-base) t)
          (my-agent--session-state session) (my-agent--object))
    (set-file-modes (my-agent--session-log-directory session) #o700)
    (dolist (channel '("stdout" "stderr" "adapter" "commands" "adapter-commands"))
      (let ((file (expand-file-name (concat channel ".log") (my-agent--session-log-directory session))))
        (write-region "" nil file nil 'silent) (set-file-modes file #o600)))
    (setf (my-agent--session-server session)
          (make-network-process :name (concat (buffer-name) " listener") :server t
                                :family 'local :service socket :noquery t
                                :coding 'utf-8-unix
                                :log (lambda (server client message) (my-agent--accept owner session server client message))))
    (set-file-modes socket #o600)
    (setenv "MY_AGENT_SOCKET" socket) (setenv "MY_AGENT_TOKEN" token)
    ;; Do not inherit a launching agent's metadata as this session's identity.
    (dolist (name '("PI_SESSION_ID" "PI_SESSION_FILE" "PI_PROVIDER" "PI_MODEL" "PI_REASONING_LEVEL")) (setenv name nil))
    (let ((stderr (make-pipe-process :name (concat (buffer-name) " stderr") :noquery t
                                     :coding 'utf-8-unix
                                     :filter (lambda (proc chunk) (my-agent--filter owner session "stderr" proc chunk)))))
      (setf (my-agent--session-stderr session) stderr
            (my-agent--session-process session)
            (make-process
             :name (buffer-name) :buffer (current-buffer) :connection-type 'pipe
             :command (cons my-agent-program args) :coding 'utf-8-unix :stderr stderr
             :noquery nil
             :filter (lambda (proc chunk) (my-agent--filter owner session "stdout" proc chunk))
             :sentinel
             (lambda (proc event)
               (unless (process-live-p proc)
                 (my-agent--owned owner session
                                  (lambda ()
                                    (my-agent--finish-fragment proc "stdout")
                                    ;; Final stdout responses must be reduced
                                    ;; before failing unresolved submissions.
                                    (my-agent--enqueue 'exit event))))))))
    (unless (and (fboundp 'treesit-language-available-p)
                 (treesit-language-available-p 'markdown)
                 (treesit-language-available-p 'markdown-inline))
      (my-agent--notice "Plain Markdown presentation"
                        "Built-in Markdown grammars are unavailable. Content is preserved as plain text; install the configured Nix Emacs grammar package for highlighting." nil t))
    (my-agent--notice "Pi native interface"
                      "C-c C-c send/steer · C-c C-f follow-up · TAB expand · C-c C-p menu\nUnknown output is shown explicitly. Logs are private and may contain sensitive content.\nSame-project agents share filesystem changes; use worktrees for file isolation." nil t)
    (my-agent--refresh-state)))
(defun my-agent--kill-query ()
  (or (not (my-agent--alive-p))
      (yes-or-no-p "Stop this Pi agent and close its buffer? ")))
(defun my-agent--cleanup ()
  "Dispose resources belonging only to this buffer; logs intentionally survive."
  (when-let* ((session my-agent--session))
    (when (timerp (my-agent--session-timer session)) (cancel-timer (my-agent--session-timer session)))
    (when (timerp (my-agent--session-compose-timer session))
      (cancel-timer (my-agent--session-compose-timer session)))
    (when (timerp (my-agent--session-stats-timer session))
      (cancel-timer (my-agent--session-stats-timer session)))
    (dolist (overlay (list (my-agent--session-compose-overlay session)
                            (my-agent--session-chips session)))
      (when (and overlay (overlay-buffer overlay)) (delete-overlay overlay)))
    (setf (my-agent--session-stopped session) t)
    (when (my-agent--alive-p)
      (ignore-errors (process-send-eof (my-agent--session-process session)))
      (let ((process (my-agent--session-process session)))
        (run-at-time 3 nil (lambda () (when (process-live-p process) (delete-process process))))))
    (dolist (process (list (my-agent--session-peer session) (my-agent--session-server session)))
      (when (process-live-p process) (delete-process process)))
    (when (my-agent--session-directory session)
      (ignore-errors (delete-directory (my-agent--session-directory session) t)))))
(defun my-agent-stop (&optional force)
  "Gracefully stop this writer; prefix FORCE permits termination after timeout."
  (interactive "P")
  (when (my-agent--alive-p)
    (when (and (not force) (not (equal (my-agent--session-phase my-agent--session) "idle")))
      (user-error "Abort first, or use a prefix to stop an active agent"))
    (let ((process (my-agent--session-process my-agent--session)) (deadline (+ (float-time) 5)))
      (process-send-eof process)
      (while (and (process-live-p process) (< (float-time) deadline)) (accept-process-output nil 0.05))
      (when (process-live-p process)
        (if force (delete-process process) (user-error "Pi is still exiting; do not start another writer")))))
  (while (or (my-agent--session-incoming my-agent--session)
             (my-agent--session-backlog my-agent--session))
    (my-agent--flush))
  (my-agent--cleanup))
(defun my-agent-restart ()
  "Restart this stopped agent with its own session and preserved draft."
  (interactive)
  (when (my-agent--alive-p) (user-error "Stop this agent before restarting"))
  (when (process-live-p (my-agent--session-cli-process my-agent--session))
    (user-error "Quit the CLI writer before restarting the native interface"))
  (let ((file (my-agent--get (my-agent--session-state my-agent--session) "sessionFile"))
        (logs (my-agent--session-log-directory my-agent--session)))
    (my-agent--cleanup)
    ;; Drain already received records before invalidating callbacks. Raw retention
    ;; alone is not an excuse to omit the last visible output on restart.
    (while (or (my-agent--session-incoming my-agent--session)
               (my-agent--session-backlog my-agent--session))
      (my-agent--flush))
    ;; Preserve transcript, prompt, undo and history, but invalidate old callbacks.
    (setq my-agent--session (copy-my-agent--session my-agent--session))
    (setf (my-agent--session-process my-agent--session) nil
          (my-agent--session-peer my-agent--session) nil
          (my-agent--session-server my-agent--session) nil
          (my-agent--session-stderr my-agent--session) nil
          (my-agent--session-timer my-agent--session) nil
          (my-agent--session-incoming my-agent--session) nil
          (my-agent--session-backlog my-agent--session) nil
          (my-agent--session-dialogs my-agent--session) nil
          (my-agent--session-cards my-agent--session) nil
          (my-agent--session-ready my-agent--session) nil
          (my-agent--session-stopped my-agent--session) nil
          (my-agent--session-phase my-agent--session) "starting"
          (my-agent--session-compose-timer my-agent--session) nil
          (my-agent--session-pending my-agent--session) (make-hash-table :test #'equal)
          (my-agent--session-adapter-pending my-agent--session) (make-hash-table :test #'equal))
    (dolist (block (my-agent--session-blocks my-agent--session))
      (setf (my-agent--block-dirty block) t))
    (my-agent--notice "Previous lifecycle logs retained" (or logs "No disk log"))
    (my-agent--start (when (stringp file) file))))

;;;###autoload
(defun my-agent-new (&optional directory name)
  "Start a new independent agent in DIRECTORY with optional buffer NAME."
  (interactive (when current-prefix-arg
                 (list (read-directory-name "Agent directory: " default-directory nil t)
                       (read-string "Agent label: "))))
  (let* ((directory (file-name-as-directory
                     (file-truename (or directory (when-let* ((project (project-current nil))) (project-root project)) default-directory))))
         (environment (copy-sequence process-environment)) (paths (copy-sequence exec-path))
         (buffer (generate-new-buffer (format "*Pi · %s%s*"
                                              (file-name-nondirectory (directory-file-name directory))
                                              (if (and name (not (string-empty-p name))) (concat " · " name) "")))))
    (when (file-remote-p directory) (kill-buffer buffer) (user-error "Local Pi only; remote transport is not implemented"))
    (with-current-buffer buffer
      (my-agent-mode)
      (setq-local default-directory directory process-environment environment exec-path paths)
      (my-agent--initialize)
      (condition-case err (my-agent--start)
        (error (my-agent--cleanup) (my-agent--notice "Could not start Pi" (error-message-string err) t))))
    (pop-to-buffer buffer)
    (goto-char (point-max)) buffer))
;;;###autoload
(defun my-agent ()
  "Focus/select a project agent; use my-agent-new for another independent one."
  (interactive)
  (if (derived-mode-p 'my-agent-mode) (my-agent-prompt)
    (let* ((directory (file-truename (or (when-let* ((project (project-current nil))) (project-root project)) default-directory)))
           (buffers (cl-remove-if-not
                     (lambda (buffer)
                       (with-current-buffer buffer
                         (and (derived-mode-p 'my-agent-mode)
                              (equal directory (file-truename default-directory))))) (buffer-list))))
      (pcase (length buffers)
        (0 (my-agent-new directory))
        (1 (pop-to-buffer (car buffers)))
        (_ (pop-to-buffer (get-buffer (completing-read "Agent: " (mapcar #'buffer-name buffers) nil t))))))))

;; User input and complete control surface --------------------------------------

(defconst my-agent--local-commands
  '("help" "model" "thinking" "new" "resume" "name" "session" "tree" "fork"
    "clone" "compact" "copy" "export" "reload" "tools" "settings" "queues"
    "logs" "rpc" "quit" "login" "logout" "share" "bug" "import" "trust"
    "scoped-models" "hotkeys" "changelog" "llama")
  "Commands handled locally rather than accidentally sent as model prompts.")

(defun my-agent--shell (draft)
  "Run ! or !! DRAFT through Pi, preserving full live shell output."
  (let* ((exclude (string-prefix-p "!!" draft))
         (command (substring draft (if exclude 2 1))) id)
    (when (string-empty-p (string-trim command)) (user-error "Empty shell command"))
    (when (equal (my-agent--session-phase my-agent--session) "idle")
      (setf (my-agent--session-phase my-agent--session) "shell"))
    (setq id
          (my-agent--rpc
           "bash" (my-agent--object "command" command "excludeFromContext" (if exclude t :false))
           (lambda (record)
             (my-agent--notice "Shell result / truncation metadata" record nil t)
             (let ((block (my-agent--tool id)))
               (setf (my-agent--block-title block) "Shell · completed"
                     (my-agent--block-dirty block) t))
             (my-agent--refresh-state))))
    (let ((block (my-agent--tool id "shell")))
      (my-agent--set-block block (concat "$ " (my-agent--code command #'sh-mode) "\n")
                           (my-agent--object "command" command)))
    t))

(defun my-agent--submit (behavior)
  (my-agent--require-live)
  (unless (my-agent--session-ready my-agent--session)
    (user-error "Pi is starting; answer any pending trust question with C-c C-d"))
  (let* ((draft (my-agent--draft))
         (attachments (my-agent--session-attachments my-agent--session))
         (message draft) images)
    (when (and (string-empty-p (string-trim draft)) (not attachments)) (user-error "Empty prompt"))
    (if (and (not attachments)
             (or (and (string-prefix-p "!" draft) (my-agent--shell draft))
                 (and (string-prefix-p "/" draft) (my-agent--dispatch-slash draft))))
        (when (equal (my-agent--draft) draft) (my-agent--set-draft ""))
      (dolist (attachment attachments)
        (if (my-agent--get attachment "image")
            (push (my-agent--get attachment "image") images)
          (setq message (concat message "\n\n" (my-agent--get attachment "text")))))
      (when (and images
                 (not (member "image" (my-agent--array
                                       (my-agent--get (my-agent--get (my-agent--session-state my-agent--session) "model") "input")))))
        (user-error "Selected model does not advertise image input"))
      (let ((data (my-agent--object "message" message "streamingBehavior" behavior))
            (submission (cons message attachments)))
        (when images (puthash "images" (vconcat (nreverse images)) data))
        (push submission (my-agent--session-submissions my-agent--session))
        ;; Register before writing; accepted, queued and handled differ from idle.
        (my-agent--rpc
         "prompt" data
         (lambda (record)
           (unless (my-agent--true (my-agent--get record "success"))
             (setf (my-agent--session-submissions my-agent--session)
                   (delq submission (my-agent--session-submissions my-agent--session)))
             (my-agent--set-draft draft t)
             (setf (my-agent--session-attachments my-agent--session)
                   (append (my-agent--session-attachments my-agent--session) attachments))
             (my-agent--notice "Rejected prompt restored (including attachments)" record t))))
        (push draft (my-agent--session-history my-agent--session))
        (setf (my-agent--session-history-index my-agent--session) -1
              (my-agent--session-attachments my-agent--session) nil
              (my-agent--session-attention my-agent--session) nil)
        (my-agent--set-draft "")
        (my-agent--refresh-composer)))))
(defun my-agent-send ()
  "Send this prompt, steering after the current turn if Pi is working."
  (interactive) (my-agent--submit "steer"))
(defun my-agent-steer ()
  "Explicitly steer this agent."
  (interactive) (my-agent--submit "steer"))
(defun my-agent-follow-up ()
  "Send this prompt after the current run completes."
  (interactive) (my-agent--submit "followUp"))
(defun my-agent-abort ()
  "Recover queued text before aborting this agent, including a direct shell."
  (interactive)
  (my-agent--require-live)
  (let* ((submissions (copy-sequence (my-agent--session-submissions my-agent--session)))
         (queue (my-agent--query "clear_queue"))
         (texts (append (my-agent--array (my-agent--get queue "steering"))
                        (my-agent--array (my-agent--get queue "followUp")))))
    ;; RPC clear_queue returns text only. Recover locally retained images rather
    ;; than silently losing them. Expanded file text is already in returned text.
    (dolist (text texts)
      (when-let* ((submission (assoc text submissions)))
        (setf (my-agent--session-attachments my-agent--session)
              (append (my-agent--session-attachments my-agent--session)
                      (cl-remove-if-not (lambda (item) (my-agent--get item "image")) (cdr submission))))
        (setq submissions (delq submission submissions))))
    (setf (my-agent--session-submissions my-agent--session) nil)
    (when texts (my-agent--set-draft (mapconcat #'identity texts "\n\n") t)))
  (my-agent--rpc "abort_bash")
  (my-agent--rpc "abort" nil (lambda (_) (my-agent--refresh-state))))
(defun my-agent-queues ()
  "Inspect this agent's reported steering/follow-up queue."
  (interactive)
  (my-agent--notice "Pending queues" (or (gethash "queues" (my-agent--session-statuses my-agent--session))
                                         "No queue update received yet.")))
(defun my-agent--history (direction)
  (let* ((session my-agent--session) (index (my-agent--session-history-index session))
         (history (my-agent--session-history session)))
    (when (= index -1) (setf (my-agent--session-history-draft session) (my-agent--draft)))
    (setq index (max -1 (min (1- (length history)) (+ index direction))))
    (setf (my-agent--session-history-index session) index)
    (my-agent--set-draft (if (= index -1) (or (my-agent--session-history-draft session) "") (nth index history)))
    (goto-char (point-max))))
(defun my-agent-history-previous () (interactive) (my-agent--history 1))
(defun my-agent-history-next () (interactive) (my-agent--history -1))

(defun my-agent-attach (file)
  "Attach a FILE snapshot, or prefix to remove existing attachments.
Text is explicit prompt context; images use Pi's image content format."
  (interactive (list (unless current-prefix-arg (read-file-name "Attach file: " nil nil t))))
  (if (not file) (setf (my-agent--session-attachments my-agent--session) nil)
    (let* ((file (expand-file-name file))
           (bytes (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))
           (type (and (fboundp 'image-type-from-data) (image-type-from-data bytes)))
           (mime (cdr (assq type '((png . "image/png") (jpeg . "image/jpeg") (gif . "image/gif") (webp . "image/webp") (bmp . "image/bmp")))))
           (attachment
            (if mime
                (my-agent--object "file" file "image"
                                  (my-agent--object "type" "image" "mimeType" mime "data" (base64-encode-string bytes t)))
              (when (string-search "\0" bytes) (user-error "Not a supported image or text file"))
              (my-agent--object "file" file "text"
                                (concat "File: " file "\n" (with-temp-buffer (insert-file-contents file) (buffer-string)))))))
      (push attachment (my-agent--session-attachments my-agent--session))
      (my-agent--notice "Attachment captured for next prompt" file nil t)))
  (my-agent--refresh-composer)
  (force-mode-line-update))
(defun my-agent--select-agent ()
  (let ((buffers (cl-remove-if-not
                  (lambda (b) (with-current-buffer b (derived-mode-p 'my-agent-mode))) (buffer-list))))
    (unless buffers (user-error "Start an agent with my-agent-new first"))
    (get-buffer (completing-read "Target agent: " (mapcar #'buffer-name buffers) nil t))))
(defun my-agent-attach-region (start end)
  "Attach an explicit source region START END to a chosen agent; do not send."
  (interactive "r")
  (let ((text (concat "Region from " (or buffer-file-name (buffer-name))
                      (format ":%d\n" (line-number-at-pos start))
                      (buffer-substring-no-properties start end)))
        (agent (my-agent--select-agent)))
    (with-current-buffer agent
      (push (my-agent--object "text" text) (my-agent--session-attachments my-agent--session))
      (my-agent--notice "Source region attached" text nil t))))

(defun my-agent--completion ()
  "Complete Pi-discovered slash commands and project files, locally per agent."
  (when (>= (point) (my-agent--session-prompt my-agent--session))
    (let* ((end (point))
           (start (save-excursion (skip-chars-backward "^ \t\n") (point)))
           (prefix (buffer-substring-no-properties start end)))
      (cond
       ((and (= start (my-agent--session-prompt my-agent--session)) (string-prefix-p "/" prefix))
        (list (1+ start) end
              (append my-agent--local-commands
                      (mapcar (lambda (cmd) (my-agent--get cmd "name"))
                              (my-agent--session-commands my-agent--session))) :exclusive 'no))
       ((string-prefix-p "@" prefix)
        (let ((files (when-let* ((project (project-current nil))) (project-files project))))
          (list (1+ start) end
                (mapcar (lambda (file) (file-relative-name file default-directory)) files)
                :exclusive 'no)))
       (t (let* ((directory (or (file-name-directory prefix) ""))
                 (base (+ start (length directory)))
                 (files (ignore-errors (file-name-all-completions
                                        (file-name-nondirectory prefix)
                                        (expand-file-name directory default-directory)))))
            (when files (list base end files :exclusive 'no))))))))

(defun my-agent--dispatch-slash (draft)
  "Dispatch DRAFT without erasing a prompt restored by /fork or /tree."
  (let* ((name (and (string-match "\\`/\\([^ \t\n]+\\)" draft) (match-string 1 draft)))
         (local (member name my-agent--local-commands)))
    (save-current-buffer
      (when local (my-agent--set-draft ""))
      (condition-case err (my-agent--slash draft)
        (error
         (when local (my-agent--set-draft draft t))
         (signal (car err) (cdr err)))))))

(defun my-agent--restore-user-images (message)
  "Reattach received user images when restoring a fork or tree entry."
  (dolist (item (my-agent--array (my-agent--get message "content")))
    (when (equal (my-agent--get item "type") "image")
      (push (my-agent--object "image" item) (my-agent--session-attachments my-agent--session)))))

(defun my-agent--slash (draft)
  "Dispatch a known local slash DRAFT. Return non-nil if consumed."
  (when (string-match "\\`/\\([^ \t\n]+\\)\\(?:[ \t\n]+\\(.*\\)\\)?\\'" draft)
    (let ((command (match-string 1 draft)) (args (or (match-string 2 draft) "")))
      (cond
       ((member command my-agent--local-commands)
        (pcase command
          ("help" (my-agent-help))
          ("model" (my-agent-model args)) ("thinking" (my-agent-thinking args))
          ("new" (my-agent-new-session)) ("resume" (my-agent-resume (unless (string-empty-p args) args)))
          ("name" (my-agent-name args)) ("session" (my-agent-statistics))
          ("tree" (my-agent-tree)) ("fork" (my-agent-fork)) ("clone" (my-agent-clone))
          ("compact" (my-agent-compact args)) ("copy" (my-agent-copy))
          ("export" (my-agent-export (unless (string-empty-p args) args)))
          ("reload" (my-agent-reload)) ("tools" (my-agent-tools))
          ("settings" (my-agent-settings)) ("queues" (my-agent-queues))
          ("logs" (my-agent-logs)) ("rpc" (my-agent-rpc)) ("quit" (my-agent-stop))
          ("trust" (my-agent-trust))
          ("hotkeys" (my-agent-help))
          (_ (my-agent-cli (concat "/" command (unless (string-empty-p args) (concat " " args)))))) t)
       ((cl-find command (my-agent--session-commands my-agent--session)
                 :test #'equal :key (lambda (item) (my-agent--get item "name"))) nil)
       ((yes-or-no-p (format "Unknown /%s; send it as ordinary Pi input? " command)) nil)
       (t (user-error "Unknown command not sent"))))))

(defun my-agent-model (&optional selection)
  "Select a model advertised by this Pi instance, optionally SELECTION."
  (interactive)
  (let* ((models (my-agent--array (my-agent--get (my-agent--query "get_available_models") "models")))
         (choices (mapcar (lambda (model) (cons (concat (my-agent--get model "provider") "/" (my-agent--get model "id")) model)) models))
         (choice (if (and selection (not (string-empty-p selection))) selection
                   (completing-read "Model: " choices nil t)))
         (model (cdr (assoc choice choices))))
    (unless model (user-error "Model not advertised by Pi: %s" choice))
    (my-agent--query "set_model" (my-agent--object "provider" (my-agent--get model "provider") "modelId" (my-agent--get model "id")))
    (my-agent--refresh-state)))
(defun my-agent-thinking (&optional level)
  "Select a supported thinking LEVEL, not a hardcoded model capability."
  (interactive)
  (let* ((levels (my-agent--array (my-agent--get (my-agent--query "get_available_thinking_levels") "levels")))
         (level (if (and level (not (string-empty-p level))) level (completing-read "Thinking: " levels nil t))))
    (unless (member level levels) (user-error "Unsupported thinking level"))
    (my-agent--query "set_thinking_level" (my-agent--object "level" level))
    (my-agent--refresh-state)))
(defun my-agent--transition (type &optional data)
  "Make an idle session transition, preserving transcript and draft."
  (my-agent--idle)
  (let ((result (my-agent--query type data)))
    (unless (my-agent--true (my-agent--get result "cancelled"))
      ;; Keys from a different saved session must not alias old tool IDs.
      (setf (my-agent--session-index my-agent--session) (make-hash-table :test #'equal)
            (my-agent--session-seen my-agent--session) (make-hash-table :test #'equal)
            (my-agent--session-cache-previous my-agent--session) nil
            (my-agent--session-current-assistant my-agent--session) nil)
      (my-agent--refresh-state)
      ;; Wait for authoritative session file/id before restoration.
      (setf (my-agent--session-state my-agent--session) (my-agent--query "get_state"))
      (my-agent-refresh)) result))
(defun my-agent-new-session ()
  "Start a new Pi session in this buffer without deleting its transcript."
  (interactive) (my-agent--transition "new_session"))
(defun my-agent--session-owner (file)
  "Find another live buffer writing FILE without a global registry."
  (let ((owner (current-buffer)) (canonical (expand-file-name file)))
    (cl-find-if
     (lambda (buffer)
       (and (not (eq buffer owner))
            (with-current-buffer buffer
              (and my-agent--session
                   (or (my-agent--alive-p) (process-live-p (my-agent--session-cli-process my-agent--session)))
                   (equal canonical (my-agent--get (my-agent--session-state my-agent--session) "sessionFile"))))))
     (buffer-list))))
(defun my-agent-resume (&optional file)
  "Resume saved FILE; never open a second writer to an owned session."
  (interactive (when current-prefix-arg (list (read-file-name "Pi session JSONL: " nil nil t))))
  (my-agent--idle)
  (unless (or file (member "sessions" (my-agent--session-capabilities my-agent--session)))
    (setq file (read-file-name "Pi session JSONL (adapter browser unavailable): " nil nil t)))
  (let* ((sessions (unless file (my-agent--adapter-query "sessions")))
         (choices (mapcar (lambda (item)
                            (cons (format "%s · %s · %s" (my-agent--get item "cwd")
                                          (or (my-agent--get item "name") (my-agent--get item "firstMessage" ""))
                                          (my-agent--get item "path")) (my-agent--get item "path")))
                          (my-agent--array sessions)))
         (file (expand-file-name (or file (cdr (assoc (completing-read "Resume: " choices nil t) choices)))))
         (owner (my-agent--session-owner file)))
    (if owner (pop-to-buffer owner)
      (my-agent--transition "switch_session" (my-agent--object "sessionPath" file)))))
(defun my-agent-name (&optional name)
  (interactive)
  (let ((name (if (and name (not (string-empty-p name))) name (read-string "Session name: "))))
    (my-agent--query "set_session_name" (my-agent--object "name" name)) (my-agent--refresh-state)))
(defun my-agent-fork ()
  "Fork from an earlier user message using Pi's supported transition API."
  (interactive)
  (let* ((messages (my-agent--array (my-agent--get (my-agent--query "get_fork_messages") "messages")))
         (choices (mapcar (lambda (message) (cons (concat (my-agent--get message "entryId") " · " (my-agent--get message "text")) message)) messages))
         (choice (cdr (assoc (completing-read "Fork: " choices nil t) choices)))
         (entry (cl-find (my-agent--get choice "entryId")
                         (my-agent--array (my-agent--get (my-agent--query "get_entries") "entries"))
                         :test #'equal :key (lambda (item) (my-agent--get item "id"))))
         (result (my-agent--transition "fork" (my-agent--object "entryId" (my-agent--get choice "entryId")))))
    (unless (my-agent--true (my-agent--get result "cancelled"))
      (when (my-agent--get result "text") (my-agent--set-draft (my-agent--get result "text") t))
      (my-agent--restore-user-images (my-agent--get entry "message")))))
(defun my-agent-clone () (interactive) (my-agent--transition "clone"))
(defun my-agent-tree ()
  "Inspect raw entries or navigate via the adapter, retaining branches."
  (interactive)
  (my-agent--idle)
  (let* ((data (my-agent--query "get_entries"))
         (entries (my-agent--array (my-agent--get data "entries")))
         (choices (mapcar (lambda (entry)
                            (cons (format "%s ← %s · %s · %s"
                                          (my-agent--get entry "id") (my-agent--get entry "parentId" "root")
                                          (my-agent--get entry "type")
                                          (truncate-string-to-width
                                           (my-agent--content-text (my-agent--get (my-agent--get entry "message") "content")) 100 nil nil "…")) entry)) entries))
         (entry (cdr (assoc (completing-read "Tree entry: " choices nil t) choices)))
         (action (completing-read "Action: " '("Inspect" "Navigate" "Navigate with summary" "Label") nil t nil nil "Inspect")))
    (pcase action
      ("Inspect" (my-agent--notice "Session tree entry" entry))
      ("Label" (my-agent--adapter-query "label" (my-agent--object "entryId" (my-agent--get entry "id") "label" (read-string "Label (empty clears): "))))
      (_ (let ((result (my-agent--adapter-query "tree" (my-agent--object "entryId" (my-agent--get entry "id")
                                                                         "summarize" (if (equal action "Navigate with summary") t :false)))))
           (unless (my-agent--true (my-agent--get result "cancelled"))
             (let* ((message (my-agent--get entry "message")) (content (my-agent--get message "content")))
               (when (equal (my-agent--get message "role") "user")
                 (my-agent--set-draft (if (stringp content) content
					(mapconcat (lambda (item) (my-agent--get item "text" ""))
                                                   (my-agent--array content) "")) t)
                 (my-agent--restore-user-images message)))
             (my-agent-refresh)))))))
(defun my-agent-compact (&optional instructions)
  (interactive)
  (my-agent--idle)
  (my-agent--rpc "compact" (my-agent--object "customInstructions" (or instructions (read-string "Compaction instructions: ")))
                 (lambda (record) (my-agent--notice "Manual compaction result" record) (my-agent--refresh-state))))
(defun my-agent-copy ()
  (interactive)
  (let ((text (my-agent--get (my-agent--query "get_last_assistant_text") "text")))
    (unless (stringp text) (user-error "No assistant text")) (kill-new text) (message "Pi reply copied")))
(defun my-agent-export (&optional file)
  "Export through Pi to HTML. For untouched JSONL, copy the session explicitly."
  (interactive)
  (let ((file (or file (read-file-name "Export HTML: " default-directory nil nil "pi-session.html"))))
    (if (string-suffix-p ".jsonl" file t)
        (let ((source (my-agent--get (my-agent--query "get_state") "sessionFile")))
          (unless (stringp source) (user-error "No saved JSONL session yet"))
          (when (or (not (file-exists-p file)) (yes-or-no-p "Overwrite export? "))
            (copy-file source file t) (set-file-modes file #o600)
            (my-agent--notice "JSONL exported (all persisted branches; review before sharing)" file)))
      (my-agent--notice "Export created (review before sharing)"
                        (my-agent--query "export_html" (my-agent--object "outputPath" (expand-file-name file)))))))
(defun my-agent-reload ()
  (interactive) (my-agent--idle) (my-agent--adapter-query "reload") (my-agent--refresh-state))
(defun my-agent-tools ()
  "Inspect or change active tools using Pi's existing tool registry."
  (interactive)
  (let* ((snapshot (my-agent--adapter-query "snapshot"))
         (tools (my-agent--array (my-agent--get snapshot "tools")))
         (names (mapcar (lambda (tool) (my-agent--get tool "name")) tools))
         (active (my-agent--array (my-agent--get snapshot "activeTools")))
         (selected (completing-read-multiple "Active tools (comma separated): " names nil t (string-join active ","))))
    (my-agent--notice "Active tools" (my-agent--adapter-query "tools" (my-agent--object "names" (vconcat selected))))))
(defun my-agent-trust ()
  "Manage Pi's saved decision for this workspace, applying on next startup."
  (interactive)
  (my-agent--idle)
  (let ((choice (completing-read "Future project trust: " '("Forget" "Allow" "Decline") nil t nil nil "Decline")))
    (my-agent--notice "Trust decision saved · restart to apply"
                      (my-agent--adapter-query "trust" (my-agent--object "decision" choice)))))

(defun my-agent-settings ()
  "Inspect effective settings; change declarative defaults in Nix, not /settings."
  (interactive)
  (my-agent--notice "Effective settings / resources / system prompt"
                    (my-agent--adapter-query "snapshot")))
(defun my-agent-statistics ()
  (interactive)
  (my-agent-stats))
(defun my-agent-rpc ()
  "Execute any Pi RPC command, exposing unsupported or new controls."
  (interactive)
  (let* ((record (my-agent--parse (read-string "RPC JSON object: " "{\"type\":\"get_state\"}")))
         (type (my-agent--get record "type")))
    (unless (stringp type) (user-error "RPC requires a type"))
    (my-agent--notice (concat "RPC · " type) (my-agent--query type record))))
(defun my-agent-logs ()
  "Open this agent's private logs; never upload or delete them implicitly."
  (interactive)
  (let* ((directory (my-agent--session-log-directory my-agent--session))
         (fallbacks (my-agent--session-fallbacks my-agent--session))
         (choices (append (when directory (directory-files directory t "\\.log\\'"))
                          (let (buffers) (maphash (lambda (_ buffer) (push (buffer-name buffer) buffers)) fallbacks) buffers)))
         (choice (completing-read "Private log (may contain secrets): " choices nil t)))
    (if (get-buffer choice) (display-buffer (get-buffer choice)) (find-file-other-window choice))))
(defun my-agent-cli (&optional command)
  "Explicit last-resort CLI handoff; stop this writer before opening Pi.
COMMAND is shown as a manual instruction, never typed/executed automatically."
  (interactive)
  (my-agent--idle)
  (let ((file (my-agent--get (my-agent--query "get_state") "sessionFile")))
    (unless (stringp file) (user-error "No saved session yet; send a prompt before handoff"))
    (when (process-live-p (my-agent--session-cli-process my-agent--session))
      (user-error "This session already has a CLI writer"))
    (unless (yes-or-no-p (format "Stop native agent and hand off %s to Pi CLI? " file)) (user-error "Handoff cancelled"))
    (puthash "sessionFile" file (my-agent--session-state my-agent--session))
    (my-agent-stop)
    (let* ((process-environment (copy-sequence process-environment))
           (name (generate-new-buffer-name (concat (buffer-name) " CLI"))))
      (setenv "MY_AGENT_SOCKET" nil) (setenv "MY_AGENT_TOKEN" nil)
      (require 'term)
      (let ((buffer (make-term name my-agent-program nil "--session" file)))
        (setf (my-agent--session-cli-process my-agent--session) (get-buffer-process buffer))
        (with-current-buffer buffer (term-mode) (term-char-mode)
                             (setq-local term-buffer-maximum-size 0))
        (my-agent--notice "CLI handoff" (concat "Native writer stopped. Quit the CLI before my-agent-restart."
						(when command (concat "\nRun manually in Pi: " command))))
        (pop-to-buffer buffer)))))
(defun my-agent-help ()
  (interactive)
  (my-agent--notice
   "Native Pi controls"
   (concat "C-c C-c send/steer; C-c C-f follow-up; C-c C-k recover queues + abort\n"
           "C-c C-d pending dialog; C-c C-a attach (prefix clears); C-c C-j prompt\n"
           "TAB fold/complete; C-c C-o fold tools/thinking; M-p/M-n input history\n"
           "C-c C-v visit file/link; C-c C-l private logs; C-c C-p menu\n\n/"
           (string-join my-agent--local-commands "  /")
           "\n\n/settings inspects effective settings; change declarative defaults in Nix."
           "\n/rpc exposes every protocol command, including newly added commands."
           "\n/login, /logout, /share, /bug and terminal-only UI require explicit CLI handoff."
           "\n@ completion inserts a path reference; attach files to include exact content."
           "\nOne buffer/process/session per agent. Other sessions may edit the same files.")))
(defun my-agent-menu ()
  "Discover this agent's native actions and Pi-provided commands."
  (interactive)
  (let* ((actions '(("Help" . my-agent-help) ("Model" . my-agent-model) ("Thinking" . my-agent-thinking)
                    ("Pending question" . my-agent-answer) ("Queues" . my-agent-queues)
                    ("Attach file/image" . my-agent-attach) ("New session" . my-agent-new-session)
                    ("Resume" . my-agent-resume) ("Tree" . my-agent-tree) ("Fork" . my-agent-fork)
                    ("Clone" . my-agent-clone) ("Name" . my-agent-name) ("Compact" . my-agent-compact)
                    ("Tools" . my-agent-tools) ("Settings/resources" . my-agent-settings)
                    ("Statistics" . my-agent-stats) ("Events" . my-agent-events)
                    ("Project trust" . my-agent-trust) ("Copy reply" . my-agent-copy)
                    ("Export" . my-agent-export) ("Reload" . my-agent-reload)
                    ("Refresh history" . my-agent-refresh) ("Redraw presentation" . my-agent-redraw)
                    ("Raw RPC" . my-agent-rpc)
                    ("Logs" . my-agent-logs) ("CLI handoff" . my-agent-cli)
                    ("Stop" . my-agent-stop) ("Restart" . my-agent-restart)))
         (commands (mapcar (lambda (cmd) (concat "/" (my-agent--get cmd "name")))
                           (my-agent--session-commands my-agent--session)))
         (choice (completing-read "Pi: " (append (mapcar #'car actions) commands) nil t)))
    (if-let* ((action (cdr (assoc choice actions)))) (call-interactively action)
      (my-agent--set-draft (concat choice " ") t) (my-agent-prompt))))

(provide 'my-agent)
;;; my-agent.el ends here
