#lang racket/base

;; domain/agent/prompt.rkt — system-prompt assembly (port of agent_loop.py's
;; _assemble_prompt mechanism). The Python file carries ~500 lines of prompt
;; text + a TOOL_DESCRIPTIONS map; the *engineering* is selecting only the
;; enabled tools' guidance and joining sections. That mechanism is ported here
;; with a concise base + representative per-tool lines (full text is mechanical).

(require racket/string racket/set)

(provide base-prompt tool-guidance assemble-prompt)

(define base-prompt
  (string-append
   "You are an Odysseus agent running on the user's machine. Use the tools below "
   "to accomplish the request; take one concrete step at a time.\n"
   "- YOU DECLARE WHEN THE JOB IS DONE — not a timer. End a turn one of three ways: "
   "(1) DONE — after verifying every concrete deliverable exists/succeeded, stop "
   "calling tools and write the final answer; (2) BLOCKED — say plainly what blocks "
   "you and stop; (3) keep going with the single most useful next step.\n"
   "- Never trail off mid-task, and never repeat a call you already ran."))

;; per-tool one-line guidance (subset; mirrors TOOL_DESCRIPTIONS)
(define tool-guidance
  (hash
   "bash"        "- `bash` — run a shell command; stdout/stderr return to you."
   "python"      "- `python` — execute Python to compute or test something."
   "read_file"   "- `read_file` — read a file from disk (optionally a line range)."
   "write_file"  "- `write_file` — write/save a file to disk."
   "edit_file"   "- `edit_file` — edit a file by exact string replacement (shows a diff)."
   "ls"          "- `ls` — list a directory (confined to allowed roots)."
   "glob"        "- `glob` — find files by glob pattern, newest first."
   "grep"        "- `grep` — search file contents by regex; returns file:line:match."
   "web_search"  "- `web_search` — one quick web lookup for a fact/current event."
   "web_fetch"   "- `web_fetch` — fetch and read the text of a specific URL."))

;; assemble-prompt: base + the guidance for the enabled (and not-disabled) tools.
;; #:compact? collapses tool guidance to a bare name list.
(define (assemble-prompt #:tools [tools '()] #:disabled [disabled (set)] #:compact? [compact? #f])
  (define enabled (filter (lambda (t) (not (set-member? disabled t))) tools))
  (cond
    [compact?
     (string-append base-prompt "\n\nAvailable tools: " (string-join enabled ", "))]
    [else
     (define lines (for/list ([t (in-list enabled)] #:when (hash-has-key? tool-guidance t))
                     (hash-ref tool-guidance t)))
     (if (null? lines)
         base-prompt
         (string-append base-prompt "\n\n## Tools\n" (string-join lines "\n")))]))
