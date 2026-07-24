#lang racket/base

;; domain/tools/core-tools.rkt — a representative slice of the tool catalog
;; expressed with the define-tool DSL. Compare the density here to the nested
;; dicts in src/tool_schemas.py. `module+ main` prints the JSON the LLM sees.
;;
;; Descriptions/params are byte-faithful to src/tool_schemas.py so the emitted
;; schema is identical (verified by ci/fidelity-tools.sh).

(require "dsl.rkt")

(define-tool bash
  #:description "Run a shell command (full access). Prefer a dedicated tool whenever one fits the job (reading, writing, editing, searching, or listing files); use bash only for what no dedicated tool covers (installs, git, builds, running programs, system info). Do NOT create or edit files via bash redirects/heredocs/sed -- use the dedicated file tools."
  (command string #:description "The shell command to execute"))

(define-tool python
  #:description "Execute Python code to compute a result or test something. Prefer a dedicated tool whenever one fits the job (reading, writing, or searching files); use python only for computation, data processing, or scripting no dedicated tool covers."
  (code string #:description "Python code to execute"))

(define-tool web_search
  #:description "Quick single web lookup for a fact or current event mid-task. NOT for 'research X' / 'do research on X' — those are deep-research jobs; use trigger_research instead."
  (query string #:description "Search query")
  (time_filter string #:optional #:enum ("day" "week" "month" "year")
               #:description "Optional freshness filter for news/latest/today queries"))

(define-tool web_fetch
  #:description "Fetch and read the text content of a specific URL the user names (e.g. 'check example.com', 'what's on this page <url>'). Use when you already have a concrete URL/domain. NOT for open-ended searches (use web_search) or 'research X' jobs (use trigger_research). Downloads are size-budgeted; a '[partial content: ...]' notice in the result means the body was cut short and you can re-call with full=true for the rest."
  (url string #:description "The URL or domain to fetch (http/https; a bare domain like example.com is fine)")
  (full boolean #:optional #:description "Raise the download budget to the hard cap for large pages/files. Use only after a result reported partial content."))

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

(define-tool manage_tasks
  #:description "Manage scheduled/automated tasks: list, create, edit, delete, pause, resume, or run tasks. Use this for ANY recurring/scheduled request ('every morning…', 'each day at 7:30', 'daily summarize…') — create a task rather than doing it once. Task types: llm (AI runs a prompt), research (runs the deep-research pipeline on a question), or action (built-in automation). Triggers can be time-based or event-based."
  (action string #:enum ("list" "create" "edit" "delete" "pause" "resume" "run")
          #:description "The action to perform")
  (task_id string #:optional #:description "Task ID (for edit/delete/pause/resume/run)")
  (name string #:optional #:description "Task name")
  (prompt string #:optional #:description "The instruction (for task_type=llm) or the research question (for task_type=research). Required for both.")
  (task_type string #:optional #:enum ("llm" "research" "action")
             #:description "llm = AI runs your prompt; research = runs the deep-research pipeline on the prompt as a question; action = direct built-in function")
  (action_name string #:optional
               #:enum ("tidy_sessions" "tidy_documents" "consolidate_memory" "tidy_research"
                       "summarize_emails" "draft_email_replies" "extract_email_events"
                       "classify_events" "learn_sender_signatures"
                       "test_skills" "audit_skills" "check_email_urgency")
               #:description "Built-in action (for task_type=action)")
  (trigger_type string #:optional #:enum ("schedule" "event")
                #:description "schedule = time-based, event = count-based")
  (schedule string #:optional #:enum ("once" "daily" "weekly" "monthly")
            #:description "Schedule frequency (for trigger_type=schedule)")
  (scheduled_time string #:optional #:description "HH:MM in UTC (for schedule triggers). Convert the user's stated local time using the UTC offset given in the 'Current date and time' context.")
  (scheduled_day integer #:optional #:description "Day of week 0=Mon (weekly) or day of month (monthly)")
  (trigger_event string #:optional
                 #:enum ("session_created" "message_sent" "document_created" "memory_added" "research_completed" "email_received" "skill_added")
                 #:description "Event name (for trigger_type=event)")
  (trigger_count integer #:optional #:description "Fire every N events (for trigger_type=event)")
  (output_target string #:optional #:description "Where results go. Defaults to 'session' (results land in a dedicated chat session the user reads) — this is the right choice for 'summarize for me' / 'send to me'. Do NOT go hunting for the user's email address; only use an email MCP tool name here if the user explicitly asked to be emailed AND an address is already known."))

(define-tool manage_calendar
  #:description "Manage calendar events: list events in a date range, create, update, delete. Each event can carry a tag/category (event_type) and importance level. Resolve relative dates like today/tomorrow against the 'Current date and time' system context, then pass ISO 8601 datetimes in the user's local wall time; for all-day events set all_day=true and pass YYYY-MM-DD. For event reminders/alarms, pass reminder_minutes; the tool creates the Odysseus note reminder, so do not also call manage_notes for the same reminder. Do not set rrule for single-occurrence requests such as 'next Wednesday only'; use rrule only when the user explicitly wants recurrence."
  (action string #:enum ("list_events" "create_event" "update_event" "delete_event" "list_calendars")
          #:description "Action to perform")
  (summary string #:optional #:description "Event title (for create/update)")
  (dtstart string #:optional #:description "Start ISO datetime, or YYYY-MM-DD if all_day")
  (dtend string #:optional #:description "End ISO datetime; defaults to +1h (or +1 day for all_day)")
  (all_day boolean #:optional #:description "Whether this is an all-day event")
  (description string #:optional #:description "Event description / notes")
  (location string #:optional #:description "Event location")
  (uid string #:optional #:description "Event UID (for update/delete)")
  (calendar_href string #:optional #:description "Specific calendar URL (optional; defaults to first calendar)")
  (calendar string #:optional #:description "Filter list_events by calendar name or href")
  (start string #:optional #:description "list_events range start (ISO datetime). Use this for month/week requests after resolving the date range; do not pass a loose query string. Prefer start; backend also accepts start_time, start_date, range_start, from, dtstart, since.")
  (end string #:optional #:description "list_events range end (ISO datetime). Use this for month/week requests after resolving the date range; defaults to +14 days only when no range is requested. Prefer end; backend also accepts end_time, end_date, range_end, to, dtend, until.")
  (event_type string #:optional #:description "Tag / category for the event. Common values: work, personal, health, travel, meal, social, admin, other. Aliases accepted: tag, category, type.")
  (importance string #:optional #:enum ("low" "normal" "high" "critical")
              #:description "Priority level (defaults to 'normal')")
  (reminder_minutes integer #:optional #:description "For create_event: create an Odysseus reminder this many minutes before the event, e.g. 5 for 'reminder 5 min before'.")
  (rrule string #:optional #:description "Recurrence rule in iCalendar RRULE format, e.g. 'FREQ=WEEKLY;BYDAY=MO' for weekly on Monday. Use with create_event or update_event. For update_event, pass an explicit empty string to remove recurrence and make the event single-occurrence."))

(define-tool manage_notes
  #:description "Manage notes and checklists (Google Keep-style): list, view, add, update, delete, toggle_item. Use list/search to find candidate notes, then view with the note id when you need the full body. IMPORTANT: For to-do lists / checklists, set note_type='checklist' and pass the items as the `checklist_items` array — do NOT serialize them into `content` as plain text. For freeform notes, use note_type='note' and put the body in `content`. `due_date` accepts natural language like 'tomorrow at 9am' (parsed in the user's timezone) and fires a notification — do not also create a calendar event for the same reminder."
  (action string #:enum ("list" "search" "view" "add" "update" "delete" "toggle_item")
          #:description "The action to perform")
  (query string #:optional #:description "Search text for action='search'")
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

(define-tool manage_endpoints
  #:description "Manage model API endpoints: list configured endpoints, add new ones, delete, enable or disable them."
  (action string #:enum ("list" "add" "delete" "enable" "disable"))
  (endpoint_id string #:optional #:description "Endpoint ID (for delete/enable/disable)")
  (name string #:optional #:description "Display name (for add)")
  (base_url string #:optional #:description "API base URL e.g. https://api.openai.com/v1 (for add)")
  (api_key string #:optional #:description "API key (for add)"))

(define-tool manage_mcp
  #:description "Manage MCP (Model Context Protocol) tool servers: list servers and their tools, add new servers, delete, enable/disable, reconnect, or list all available tools."
  (action string #:enum ("list" "add" "delete" "enable" "disable" "reconnect" "list_tools"))
  (server_id string #:optional #:description "Server ID (for delete/enable/disable/reconnect)")
  (name string #:optional #:description "Server name (for add)")
  (command string #:optional #:description "Command to run e.g. npx (for add)")
  (args array #:optional #:items string #:description "Command arguments (for add)")
  (env object #:optional #:description "Environment variables (for add)"))

(define-tool manage_webhooks
  #:description "Manage webhooks: list, add, delete, enable or disable webhook endpoints."
  (action string #:enum ("list" "add" "delete" "enable" "disable"))
  (webhook_id string #:optional #:description "Webhook ID (for delete/enable/disable)")
  (name string #:optional #:description "Webhook name (for add)")
  (url string #:optional #:description "Webhook URL (for add)")
  (events string #:optional #:description "Comma-separated event names (for add)"))

(define-tool manage_tokens
  #:description "Manage API access tokens: list existing tokens, create new ones, or delete them."
  (action string #:enum ("list" "create" "delete"))
  (token_id string #:optional #:description "Token ID (for delete)")
  (name string #:optional #:description "Token name (for create)"))

(define-tool manage_skills
  #:description "Read or modify the user's skill library. Skills are SKILL.md files (YAML frontmatter + structured body: When to Use / Procedure / Pitfalls / Verification) and follow a draft → published lifecycle. Use progressive disclosure: 'list' to see what exists, 'view' to load full content for a single skill, 'view_ref' for sub-files. Use 'patch' for surgical text edits and 'edit' for full rewrites. 'publish' once you've verified the procedure works. For add, always provide an explicit name slug and only tell the user the exact name returned by the tool."
  (action string #:enum ("list" "view" "view_ref" "add" "edit" "patch" "publish" "delete" "search")
          #:description "list = name+description summary; view = full SKILL.md; view_ref = sub-file under the skill dir; add = create; edit = full rewrite (content); patch = old_string→new_string; publish = flip status; delete; search = relevance match on published skills.")
  (name string #:optional #:description "Slug/name of the skill. Required for add/view/view_ref/edit/patch/publish/delete. For add, choose the exact kebab-case name the user should see and report only the returned name.")
  (path string #:optional #:description "Sub-path under the skill directory for view_ref (e.g. 'references/example.md').")
  (description string #:optional #:description "One-line summary surfaced in the skills index (for add).")
  (category string #:optional #:description "Organizational grouping like 'dev', 'email', 'system' (for add).")
  (when_to_use string #:optional #:description "Trigger conditions in plain English (for add).")
  (procedure array #:optional #:items string #:description "Numbered steps (for add).")
  (pitfalls array #:optional #:items string #:description "Known failure modes + recovery (for add).")
  (verification array #:optional #:items string #:description "How to confirm the procedure succeeded (for add).")
  (tags array #:optional #:items string #:description "Keyword tags (for add).")
  (platforms array #:optional #:items string #:description "Restrict to OSes (for add).")
  (requires_toolsets array #:optional #:items string #:description "Hide unless these toolsets are active (for add).")
  (fallback_for_toolsets array #:optional #:items string #:description "Hide when these toolsets are active (for add).")
  (status string #:optional #:enum ("draft" "published") #:description "Defaults to 'draft' on add.")
  (version string #:optional #:description "Semver-ish, e.g. '1.0.0' (for add).")
  (confidence number #:optional #:description "0-1 (for add/publish).")
  (content string #:optional #:description "Full SKILL.md text (for edit).")
  (old_string string #:optional #:description "Exact substring to replace (for patch). Must appear exactly once.")
  (new_string string #:optional #:description "Replacement text (for patch).")
  (query string #:optional #:description "Search query (for search)."))

(define-tool manage_documents
  #:description "Manage documents: list all documents (with optional search/language filter), delete documents, or run tidy cleanup."
  (action string #:enum ("list" "delete" "tidy"))
  (document_id string #:optional #:description "Document ID (for delete)")
  (search string #:optional #:description "Search query (for list)")
  (language string #:optional #:description "Filter by language (for list)")
  (limit integer #:optional #:description "Max results (for list, default 50)"))

(define-tool manage_settings
  #:description "Manage user preferences and settings. Use `disable_tool`/`enable_tool`/`list_tools` to turn individual tools on or off globally (e.g. shell, search, browser, documents, memory, skills, images, tasks, notes, calendar, email). Use list/get/set/delete for free-form preferences."
  (action string #:enum ("list" "get" "set" "delete" "disable_tool" "enable_tool" "list_tools"))
  (key string #:optional #:description "Setting key (for get/set/delete)")
  (value _ #:optional #:description "Setting value (for set) — can be string, number, boolean, or object")
  (tool string #:optional #:description "Tool name to disable/enable (for disable_tool/enable_tool). Accepts aliases: shell, search, browser, documents, memory, skills, images, tasks, notes, calendar, email — or a raw tool name like 'bash' or 'web_search'."))

(module+ main
  (require json)
  (write-json (all-tool-schemas))
  (newline))
