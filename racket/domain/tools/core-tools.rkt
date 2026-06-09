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

(module+ main
  (require json)
  (write-json (all-tool-schemas))
  (newline))
