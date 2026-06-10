#lang racket/base

;; domain/tools/core-tools.rkt — a representative slice of the tool catalog
;; expressed with the define-tool DSL. Compare the density here to the nested
;; dicts in src/tool_schemas.py. `module+ main` prints the JSON the LLM sees.
;;
;; Descriptions/params are byte-faithful to src/tool_schemas.py so the emitted
;; schema is identical (verified by ci/fidelity-tools.sh).

(require "dsl.rkt")

(define-tool bash
  #:description "Run a shell command (full access)"
  (command string #:description "The shell command to execute"))

(define-tool python
  #:description "Execute Python code to compute a result or test something"
  (code string #:description "Python code to execute"))

(define-tool web_search
  #:description "Quick single web lookup for a fact or current event mid-task. NOT for 'research X' / 'do research on X' — those are deep-research jobs; use trigger_research instead."
  (query string #:description "Search query")
  (time_filter string #:optional #:enum ("day" "week" "month" "year")
               #:description "Optional freshness filter for news/latest/today queries"))

(define-tool web_fetch
  #:description "Fetch and read the text content of a specific URL the user names (e.g. 'check example.com', 'what's on this page <url>'). Use when you already have a concrete URL/domain. NOT for open-ended searches (use web_search) or 'research X' jobs (use trigger_research)."
  (url string #:description "The URL or domain to fetch (http/https; a bare domain like example.com is fine)"))

(define-tool read_file
  #:description "Read a file from disk. Optionally read a line range with offset/limit for large files."
  (path string #:description "File path to read")
  (offset integer #:optional #:description "1-based line to start reading from (optional)")
  (limit integer #:optional #:description "Max number of lines to read from offset (optional)"))

(define-tool grep
  #:description "Search file contents for a regular expression across a directory tree (uses ripgrep when available, respecting .gitignore). Returns file:line:match. PREFER this over `bash grep/rg` for code search — confined to the allowed roots, structured output."
  (pattern string #:description "Regular expression to search for")
  (path string #:optional #:description "Directory or file to search (optional; defaults to the project root)")
  (glob string #:optional #:description "Only search files matching this glob, e.g. '*.py' (optional)")
  (ignore_case boolean #:optional #:description "Case-insensitive match (optional)")
  (max_results integer #:optional #:description "Max matches to return (optional)"))

(define-tool glob
  #:description "Find files by glob pattern (recursive), newest first. e.g. '**/*.py'. PREFER this over `bash find/ls` for locating files — confined to the allowed roots."
  (pattern string #:description "Glob pattern, e.g. '**/*.ts' or 'src/**/test_*.py'")
  (path string #:optional #:description "Base directory (optional; defaults to the project root)"))

(define-tool ls
  #:description "List the entries of a directory (folders first, then files with sizes). PREFER this over `bash ls` — confined to the allowed roots."
  (path string #:optional #:description "Directory to list (optional; defaults to the project root)"))

(define-tool write_file
  #:description "Write/save a file to disk"
  (path string #:description "File path to write to")
  (content string #:description "File content to write"))

(define-tool edit_file
  #:description "Edit a file ON DISK by exact string replacement (home folder, project files, any real path like ~/sweden.txt or /path/to/file). This is the right tool for files on disk — NOT edit_document (that's for editor-panel documents). PREFER this over bash (sed/echo) — it shows a diff. old_string must match the file exactly and be unique (or set replace_all). Use write_file to create a new file."
  (path string #:description "File path to edit")
  (old_string string #:description "Exact text to replace (must match the file, including indentation)")
  (new_string string #:description "Replacement text")
  (replace_all boolean #:optional #:description "Replace all occurrences instead of requiring a unique match"))

(define-tool manage_notes
  #:description "Manage notes and checklists (Google Keep-style): list, add, update, delete, toggle_item. IMPORTANT: For to-do lists / checklists, set note_type='checklist' and pass the items as the `checklist_items` array — do NOT serialize them into `content` as plain text. For freeform notes, use note_type='note' and put the body in `content`. `due_date` accepts natural language like 'tomorrow at 9am' (parsed in the user's timezone) and fires a notification — do not also create a calendar event for the same reminder."
  (action string #:enum ("list" "add" "update" "delete" "toggle_item")
          #:description "The action to perform")
  (id string #:optional #:description "Note id (for update/delete/toggle_item); 8-char prefix is fine")
  (title string #:optional #:description "Note title (for add/update)")
  (content string #:optional #:description "Freeform body text. Use this for note_type='note'. Do NOT use this for checklists — pass `checklist_items` instead.")
  (note_type string #:optional #:enum ("note" "checklist")
             #:description "'note' = freeform text in `content`. 'checklist' = structured to-do items in `checklist_items`. Defaults to 'checklist' if checklist_items is supplied, else 'note'.")
  (checklist_items array #:optional
    #:items-of ((text string #:description "The to-do item text")
                (done boolean #:optional #:description "Whether the item is checked off"))
    #:description "Checklist items for note_type='checklist'. Each item is {text, done}. REQUIRED for checklists — leaving this empty produces a blank note.")
  (color string #:optional #:description "Optional color label (e.g. 'yellow', 'blue', 'green')")
  (label string #:optional #:description "Optional category label (also used as a list filter)")
  (pinned boolean #:optional #:description "Pin the note to the top")
  (archived boolean #:optional #:description "For update: archive/unarchive. For list: show archived notes when true.")
  (due_date string #:optional #:description "Reminder time. Accepts natural language ('tomorrow at 9am', '11pm today') or ISO 8601. Fires a notification at that time.")
  (index integer #:optional #:description "Checklist item index (for toggle_item, 0-based)"))

(module+ main
  (require json)
  (write-json (all-tool-schemas))
  (newline))
