#lang racket/base

;; racket/test/run-tests.rkt — portable behavior tests for the ported CLIs.
;;
;; Pure Racket (rackunit + subprocess), so it runs identically on Linux, macOS,
;; and Windows — no bash/PowerShell/Python needed. CI runs this on every
;; platform agent. Python-vs-Racket *fidelity* diffs (which need the app venv)
;; live in ci/fidelity.sh and run on the Linux agent only.
;;
;;   racket test/run-tests.rkt        # from the racket/ dir

(require rackunit
         rackunit/text-ui
         racket/system
         racket/port
         racket/file
         json
         db
         "../domain/notes.rkt"      ; web-shape route serializer
         "../domain/tasks.rkt"      ; manage_tasks agent tool
         "../domain/integrations.rkt" ; manage_{endpoints,mcp,webhooks,tokens}
         "../domain/documents.rkt"  ; manage_documents agent tool
         "../domain/settings-tool.rkt" ; manage_settings agent tool
         "../domain/skill-format.rkt" ; SKILL.md round-trip
         "../domain/skills.rkt"     ; manage_skills agent tool
         "../domain/nl-datetime.rkt" ; calendar datetime engine
         "../domain/calendar-tool.rkt" ; manage_calendar agent tool
         "../domain/tools/dsl.rkt"        ; tool-schema DSL
         "../domain/tools/core-tools.rkt"    ; registers the ported tools on load
         "../domain/tools/convert.rkt"       ; native-call → ToolBlock converter
         "../domain/tools/result.rkt"        ; tool-result->text renderer
         "../domain/agent/loop.rkt"          ; agent loop control spine
         "../domain/agent/llm.rkt"           ; OpenAI response parser + streaming (#:llm edge)
         "../domain/agent/exec.rkt"          ; tool dispatcher (#:exec edge)
         "../domain/agent/prompt.rkt"        ; system-prompt assembly
         racket/string racket/set racket/date)

(define racket-bin (find-executable-path "racket"))
;; tests are run from the racket/ dir, so CLI sources are under cli/
(define (cli name) (path->string (build-path "cli" name)))

;; Run a CLI source file with args + env; return (values exit-code stdout-string).
(define (run-cli src args #:env [env '()])
  (define out (open-output-string))
  (define code
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-nowhere)]
                   [current-environment-variables
                    (let ([e (environment-variables-copy (current-environment-variables))])
                      (for ([kv (in-list env)])
                        (environment-variables-set! e (string->bytes/utf-8 (car kv))
                                                   (string->bytes/utf-8 (cdr kv))))
                      e)])
      (apply system*/exit-code racket-bin src args)))
  (values code (get-output-string out)))

(define (run-json src args #:env [env '()])
  (define-values (code out) (run-cli src args #:env env))
  (check-equal? code 0 (format "~a ~a exited ~a" src args code))
  (string->jsexpr out))

;; ---- fixtures --------------------------------------------------------------

(define tmp (make-temporary-file "odyrkt~a" 'directory))
(define data-dir (build-path tmp "data"))
(make-directory* data-dir)
(define db-path (build-path tmp "app.db"))
(define env-data (list (cons "ODYSSEUS_DATA_DIR" (path->string data-dir))))
(define env-db (list (cons "DATABASE_URL"
                           (string-append "sqlite:///" (path->string db-path)))))

(define (seed-db!)
  (define c (sqlite3-connect #:database db-path #:mode 'create))
  (query-exec c "DROP TABLE IF EXISTS signatures")
  (query-exec c (string-append
                 "CREATE TABLE signatures(id TEXT PRIMARY KEY, owner TEXT, name TEXT, "
                 "width INTEGER, height INTEGER, data_png TEXT, svg TEXT, created_at TEXT)"))
  ;; a real 1x1 PNG as a data URL
  (define png-data-url
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=")
  (query-exec c "INSERT INTO signatures VALUES(?,?,?,?,?,?,?,?)"
              "sig1" "alice" "Alice" 200 80 png-data-url "<svg/>" "2026-01-02T03:04:05")
  (query-exec c "INSERT INTO signatures VALUES(?,?,?,?,?,?,?,?)"
              "sig2" sql-null "NoOwner" 100 40 png-data-url sql-null "2026-02-02T00:00:00")
  (disconnect c))

;; SQLAlchemy stores DateTime as "YYYY-MM-DD HH:MM:SS.ffffff" — seed both a
;; zero-fraction (becomes ...T...:00) and a non-zero one to exercise the converter.
(define long-prompt (make-string 250 #\x))

(define (seed-rows!)
  (define c (sqlite3-connect #:database db-path #:mode 'create))
  ;; notes
  (query-exec c "DROP TABLE IF EXISTS notes")
  (query-exec c (string-append
    "CREATE TABLE notes(id TEXT PRIMARY KEY,owner TEXT,title TEXT,content TEXT,items TEXT,"
    "note_type TEXT,color TEXT,label TEXT,pinned INT,archived INT,due_date TEXT,source TEXT,"
    "session_id TEXT,sort_order INT,image_url TEXT,repeat TEXT,ai_classification TEXT,"
    "ai_content_hash TEXT,agent_session_id TEXT,created_at TEXT,updated_at TEXT)"))
  (query-exec c (string-append
    "INSERT INTO notes(id,title,content,items,note_type,label,pinned,archived,source,sort_order,created_at,updated_at)"
    " VALUES('n1','Alpha','hello world','[{\"text\":\"a\",\"done\":false}]','note','work',1,0,'user',0,"
    "'2026-03-01 09:00:00.000000','2026-03-03 09:00:00.000000')"))
  (query-exec c (string-append
    "INSERT INTO notes(id,title,content,note_type,pinned,archived,source,sort_order,created_at,updated_at)"
    " VALUES('n2','Beta archived','secret','note',0,1,'user',0,"
    "'2026-03-02 10:00:00.123456','2026-03-02 10:00:00.123456')"))
  ;; sessions
  (query-exec c "DROP TABLE IF EXISTS sessions")
  (query-exec c (string-append
    "CREATE TABLE sessions(id TEXT PRIMARY KEY,name TEXT,model TEXT,endpoint_url TEXT,owner TEXT,"
    "folder TEXT,archived INT,rag INT,is_important INT,message_count INT,total_input_tokens INT,"
    "total_output_tokens INT,last_accessed TEXT,created_at TEXT)"))
  (query-exec c (string-append
    "INSERT INTO sessions VALUES('s1','Chat one','gpt','http://x','alice','work',0,1,0,5,100,200,"
    "'2026-03-05 12:00:00.000000','2026-03-01 08:00:00.000000')"))
  (query-exec c (string-append
    "INSERT INTO sessions VALUES('s2','Old chat','gpt','http://x',NULL,NULL,1,0,0,0,0,0,"
    "'2026-02-01 00:00:00.000000','2026-01-01 00:00:00.000000')"))
  ;; scheduled_tasks + task_runs
  (query-exec c "DROP TABLE IF EXISTS scheduled_tasks")
  (query-exec c (string-append
    "CREATE TABLE scheduled_tasks(id TEXT PRIMARY KEY,name TEXT,task_type TEXT,action TEXT,prompt TEXT,"
    "schedule TEXT,scheduled_time TEXT,next_run TEXT,last_run TEXT,status TEXT,model TEXT,run_count INT,"
    "cron_expression TEXT,endpoint_url TEXT,session_id TEXT,webhook_token TEXT)"))
  (query-exec c (string-append
    "INSERT INTO scheduled_tasks(id,name,task_type,prompt,schedule,scheduled_time,next_run,status,model,"
    "run_count,cron_expression,endpoint_url,webhook_token) VALUES('t1','Nightly','llm',?,'daily','02:00',"
    "'2026-03-10 02:00:00.000000','active','gpt',3,'0 2 * * *','http://x','tok123')") long-prompt)
  (query-exec c "DROP TABLE IF EXISTS task_runs")
  (query-exec c (string-append
    "CREATE TABLE task_runs(id TEXT PRIMARY KEY,task_id TEXT,started_at TEXT,finished_at TEXT,"
    "status TEXT,result TEXT)"))
  (query-exec c (string-append
    "INSERT INTO task_runs VALUES('r1','t1','2026-03-10 02:00:00.000000',"
    "'2026-03-10 02:00:05.000000','success','ok output')"))
  (query-exec c (string-append
    "INSERT INTO task_runs VALUES('r2','t1','2026-03-09 02:00:00.000000',NULL,'error','boom')"))
  ;; mcp_servers
  (query-exec c "DROP TABLE IF EXISTS mcp_servers")
  (query-exec c (string-append
    "CREATE TABLE mcp_servers(id TEXT PRIMARY KEY,name TEXT,transport TEXT,command TEXT,args TEXT,"
    "env TEXT,url TEXT,is_enabled INT,oauth_config TEXT,created_at TEXT)"))
  (query-exec c (string-append
    "INSERT INTO mcp_servers VALUES('m1','Filesystem','stdio','npx','[\"server-fs\",\"/tmp\"]',"
    "'{\"TOKEN\":\"secret\"}',NULL,1,NULL,'2026-03-01 00:00:00.000000')"))
  (query-exec c (string-append
    "INSERT INTO mcp_servers VALUES('m2','Remote','sse',NULL,NULL,NULL,'http://x',0,'{}',"
    "'2026-03-02 00:00:00.000000')"))
  ;; calendars + events
  (query-exec c "DROP TABLE IF EXISTS calendars")
  (query-exec c "CREATE TABLE calendars(id TEXT PRIMARY KEY,name TEXT,color TEXT,source TEXT,created_at TEXT)")
  (query-exec c "INSERT INTO calendars VALUES('cal1','Personal','#fff','local','2026-01-01 00:00:00.000000')")
  (query-exec c "INSERT INTO calendars VALUES('cal2','Work','#000','local','2026-01-02 00:00:00.000000')")
  (query-exec c "DROP TABLE IF EXISTS calendar_events")
  (query-exec c (string-append
    "CREATE TABLE calendar_events(uid TEXT PRIMARY KEY,calendar_id TEXT,summary TEXT,description TEXT,"
    "location TEXT,dtstart TEXT,dtend TEXT,all_day INT,is_utc INT,rrule TEXT,color TEXT,status TEXT,"
    "importance TEXT,event_type TEXT,created_at TEXT,updated_at TEXT)"))
  (query-exec c (string-append
    "INSERT INTO calendar_events VALUES('e1','cal1','Lunch','','',"
    "'2026-05-10 12:00:00.000000','2026-05-10 13:00:00.000000',0,0,'','','confirmed','normal',NULL,"
    "'2026-04-01 00:00:00.000000','2026-04-01 00:00:00.000000')"))
  (query-exec c (string-append
    "INSERT INTO calendar_events VALUES('e2','cal1','Flight (UTC)','','',"
    "'2026-05-15 08:00:00.000000','2026-05-15 11:00:00.000000',0,1,'','','confirmed','high',NULL,"
    "'2026-04-01 00:00:00.000000','2026-04-01 00:00:00.000000')"))
  (query-exec c (string-append
    "INSERT INTO calendar_events VALUES('e3','cal2','June thing','','',"
    "'2026-06-01 09:00:00.000000','2026-06-01 10:00:00.000000',0,0,'','','confirmed','normal',NULL,"
    "'2026-04-01 00:00:00.000000','2026-04-01 00:00:00.000000')"))
  (disconnect c))

;; research records are JSON files under ODYSSEUS_DATA_DIR/deep_research/
(define (seed-research!)
  (define dir (build-path data-dir "deep_research"))
  (make-directory* dir)
  (define (write-rp id jx) (call-with-output-file (build-path dir (string-append id ".json"))
                             #:exists 'replace (lambda (o) (write-json jx o))))
  (write-rp "rp1" (hasheq 'query "quantum computing" 'category "tech" 'status "done"
                          'started_at "2026-03-02T10:00:00" 'completed_at "2026-03-02T11:00:00"
                          'sources (list (hasheq 'url "a") (hasheq 'url "b"))
                          'result "# Report\nfindings about qubits"))
  (write-rp "rp2" (hasheq 'query "coffee roasting" 'category "food" 'status "running"
                          'started_at "2026-03-05T08:00:00" 'sources '()
                          'result "")))

;; ---- tests -----------------------------------------------------------------

(define suite
  (test-suite "ported CLIs"

    (test-case "odysseus-logs --version"
      (define-values (code out) (run-cli (cli "odysseus-logs.rkt") '("--version")))
      (check-equal? code 0)
      (check-true (regexp-match? #rx"odysseus-logs 0\\.1\\.0" out)))

    (test-case "odysseus-preset round-trip (set/get/list/delete)"
      (run-json (cli "odysseus-preset.rkt")
                '("set" "coder" "--temperature" "0.3" "--prompt" "Write code." "--display-name" "Coder")
                #:env env-data)
      (define got (run-json (cli "odysseus-preset.rkt") '("get" "coder") #:env env-data))
      (check-equal? (hash-ref got 'id) "coder")
      (check-equal? (hash-ref got 'name) "Coder")
      (check-equal? (hash-ref got 'system_prompt) "Write code.")
      (define lst (run-json (cli "odysseus-preset.rkt") '("list") #:env env-data))
      (check-equal? (length lst) 1)
      (check-equal? (hash-ref (car lst) 'prompt_length) 11)  ; (string-length "Write code.")
      (define del (run-json (cli "odysseus-preset.rkt") '("delete" "coder") #:env env-data))
      (check-equal? (hash-ref del 'ok) #t)
      (check-equal? (length (run-json (cli "odysseus-preset.rkt") '("list") #:env env-data)) 0))

    (test-case "odysseus-signature list/show/export/delete"
      (seed-db!)
      (define lst (run-json (cli "odysseus-signature.rkt") '("list") #:env env-db))
      (check-equal? (map (lambda (r) (hash-ref r 'id)) lst) '("sig2" "sig1")) ; created_at DESC
      (define s2 (car lst))
      (check-equal? (hash-ref s2 'owner) "")        ; null owner -> ""
      (check-equal? (hash-ref s2 'has_svg) #f)      ; null svg
      (define sig1-show (run-json (cli "odysseus-signature.rkt") '("show" "sig1") #:env env-db))
      (check-equal? (hash-ref sig1-show 'has_svg) #t)
      (define out-png (build-path tmp "out.png"))
      (define exp (run-json (cli "odysseus-signature.rkt")
                            (list "export" "sig1" "--png" (path->string out-png)) #:env env-db))
      (check-equal? (hash-ref exp 'ok) #t)
      (check-true (file-exists? out-png))
      (check-true (>= (file-size out-png) 8))       ; has PNG header at least
      (run-json (cli "odysseus-signature.rkt") '("delete" "sig2") #:env env-db)
      (check-equal? (length (run-json (cli "odysseus-signature.rkt") '("list") #:env env-db)) 1)
      ;; deleting a missing id is a clean non-zero exit
      (define-values (code _o) (run-cli (cli "odysseus-signature.rkt") '("delete" "nope") #:env env-db))
      (check-equal? code 1))

    (test-case "odysseus-notes list/show/search/create/delete"
      (seed-rows!)
      (define lst (run-json (cli "odysseus-notes.rkt") '("list") #:env env-db))
      (check-equal? (map (lambda (n) (hash-ref n 'id)) lst) '("n1"))  ; archived excluded
      (define n1 (car lst))
      (check-equal? (hash-ref n1 'pinned) #t)
      (check-equal? (hash-ref n1 'updated_at) "2026-03-03T09:00:00")  ; space->T, .000000 dropped
      (check-equal? (length (hash-ref n1 'items)) 1)                  ; items JSON parsed
      (check-equal? (hash-ref n1 'color) "")                          ; NULL -> ""
      (define arch (run-json (cli "odysseus-notes.rkt") '("list" "--archived") #:env env-db))
      (check-equal? (length arch) 2)
      (define n2 (run-json (cli "odysseus-notes.rkt") '("show" "n2") #:env env-db))
      (check-equal? (hash-ref n2 'updated_at) "2026-03-02T10:00:00.123456")  ; nonzero micros kept
      (define found (run-json (cli "odysseus-notes.rkt") '("search" "Beta") #:env env-db))
      (check-equal? (map (lambda (n) (hash-ref n 'id)) found) '("n2"))      ; search ignores archived
      (define created (run-json (cli "odysseus-notes.rkt")
                                '("create" "--title" "New" "--content" "x" "--pin") #:env env-db))
      (check-equal? (hash-ref created 'title) "New")
      (check-equal? (hash-ref created 'pinned) #t)
      (check-equal? (length (run-json (cli "odysseus-notes.rkt") '("list") #:env env-db)) 2)  ; n1 + New
      (define del (run-json (cli "odysseus-notes.rkt")
                            (list "delete" (hash-ref created 'id)) #:env env-db))
      (check-equal? (hash-ref del 'ok) #t))

    (test-case "odysseus-sessions list/archive/unarchive/delete"
      (seed-rows!)
      (define lst (run-json (cli "odysseus-sessions.rkt") '("list") #:env env-db))
      (check-equal? (map (lambda (s) (hash-ref s 'id)) lst) '("s1"))   ; archived excluded
      (check-equal? (hash-ref (car lst) 'rag) #t)
      (check-equal? (hash-ref (car lst) 'message_count) 5)
      (check-equal? (hash-ref (car lst) 'last_accessed) "2026-03-05T12:00:00")
      (check-equal? (length (run-json (cli "odysseus-sessions.rkt") '("list" "--archived") #:env env-db)) 2)
      (check-equal? (length (run-json (cli "odysseus-sessions.rkt") '("list" "--archived" "only") #:env env-db)) 1)
      (define a (run-json (cli "odysseus-sessions.rkt") '("archive" "s1") #:env env-db))
      (check-equal? (hash-ref a 'archived) #t)
      (check-equal? (length (run-json (cli "odysseus-sessions.rkt") '("list") #:env env-db)) 0)  ; s1 now archived
      (run-json (cli "odysseus-sessions.rkt") '("unarchive" "s1") #:env env-db)
      (check-equal? (length (run-json (cli "odysseus-sessions.rkt") '("list") #:env env-db)) 1)
      ;; delete needs --yes
      (define-values (code _o) (run-cli (cli "odysseus-sessions.rkt") '("delete" "s2") #:env env-db))
      (check-equal? code 1)
      (check-equal? (hash-ref (run-json (cli "odysseus-sessions.rkt") '("delete" "s2" "--yes") #:env env-db) 'ok) #t))

    (test-case "odysseus-tasks list/show/runs (+ run column mapping)"
      (seed-rows!)
      (define lst (run-json (cli "odysseus-tasks.rkt") '("list") #:env env-db))
      (check-equal? (map (lambda (t) (hash-ref t 'id)) lst) '("t1"))
      (define t1 (car lst))
      (check-equal? (hash-ref t1 'run_count) 3)
      (check-equal? (hash-ref t1 'next_run) "2026-03-10T02:00:00")
      (check-equal? (string-length (hash-ref t1 'prompt)) 201)        ; 200 + "…"
      (define show (run-json (cli "odysseus-tasks.rkt") '("show" "t1") #:env env-db))
      (check-equal? (hash-ref show 'webhook_token) "***")             ; redacted, present
      (check-equal? (string-length (hash-ref show 'prompt_full)) 250) ; full prompt
      (check-equal? (length (hash-ref show 'recent_runs)) 2)
      (define runs (run-json (cli "odysseus-tasks.rkt") '("runs") #:env env-db))
      (check-equal? (map (lambda (r) (hash-ref r 'id)) runs) '("r1" "r2"))  ; started_at DESC
      (define r1 (car runs))
      (check-equal? (hash-ref r1 'completed_at) "2026-03-10T02:00:05") ; from finished_at
      (check-equal? (hash-ref r1 'output_preview) "ok output")        ; from result
      (check-equal? (hash-ref (cadr runs) 'completed_at) ""))         ; r2 finished_at NULL

    (test-case "odysseus-mcp list/show/enable/add/delete (env redaction)"
      (seed-rows!)
      (define lst (run-json (cli "odysseus-mcp.rkt") '("list") #:env env-db))
      (check-equal? (map (lambda (m) (hash-ref m 'id)) lst) '("m1" "m2"))   ; name ASC
      (define m1 (car lst))
      (check-equal? (hash-ref m1 'is_enabled) #t)
      (check-equal? (length (hash-ref m1 'args)) 2)                         ; JSON args parsed
      (check-equal? (hash-ref (hash-ref m1 'env) 'TOKEN) "***")             ; secret redacted
      (define reveal (run-json (cli "odysseus-mcp.rkt") '("show" "m1" "--reveal") #:env env-db))
      (check-equal? (hash-ref (hash-ref reveal 'env) 'TOKEN) "secret")      ; --reveal shows value
      (run-json (cli "odysseus-mcp.rkt") '("disable" "m1") #:env env-db)
      (check-equal? (hash-ref (run-json (cli "odysseus-mcp.rkt") '("show" "m1") #:env env-db) 'is_enabled) #f)
      (define added (run-json (cli "odysseus-mcp.rkt")
                              '("add" "--name" "New" "--command" "echo" "--args" "[\"hi\"]") #:env env-db))
      (check-equal? (hash-ref added 'name) "New")
      (check-equal? (hash-ref added 'is_enabled) #t)
      (check-equal? (hash-ref (run-json (cli "odysseus-mcp.rkt")
                              (list "delete" (hash-ref added 'id)) #:env env-db) 'ok) #t))

    (test-case "odysseus-calendar calendars/list/show/create/delete (Z suffix + range)"
      (seed-rows!)
      (define cals (run-json (cli "odysseus-calendar.rkt") '("calendars") #:env env-db))
      (check-equal? (map (lambda (c) (hash-ref c 'name)) cals) '("Personal" "Work"))
      (check-equal? (hash-ref (car cals) 'event_count) 2)                  ; cal1 has e1,e2
      (define may (run-json (cli "odysseus-calendar.rkt")
                            '("list" "--start" "2026-05-01" "--end" "2026-05-31") #:env env-db))
      (check-equal? (map (lambda (e) (hash-ref e 'uid)) may) '("e1" "e2")) ; e3 (June) excluded, dtstart ASC
      (define e1 (car may))
      (check-equal? (hash-ref e1 'dtstart) "2026-05-10T12:00:00")          ; naive, no Z
      (define e2 (cadr may))
      (check-equal? (hash-ref e2 'dtstart) "2026-05-15T08:00:00Z")         ; is_utc -> Z suffix
      (check-equal? (hash-ref e2 'calendar_name) "Personal")              ; join
      ;; #2065: an in-progress event (started before the window, still running)
      ;; must appear — overlap (dtstart<end AND dtend>start), not dtstart>=start.
      ;; e1 runs 12:00-13:00; a window opening at 12:30 starts mid-event.
      (define mid (run-json (cli "odysseus-calendar.rkt")
                            '("list" "--start" "2026-05-10T12:30:00" "--end" "2026-05-12") #:env env-db))
      (check-equal? (map (lambda (e) (hash-ref e 'uid)) mid) '("e1"))     ; in-progress kept
      (define created (run-json (cli "odysseus-calendar.rkt")
                                '("create" "--title" "Standup" "--start" "2026-05-20"
                                  "--calendar" "Work") #:env env-db))
      (check-equal? (hash-ref created 'summary) "Standup")
      (check-equal? (hash-ref created 'calendar_name) "Work")
      (check-equal? (hash-ref (run-json (cli "odysseus-calendar.rkt")
                              (list "delete" (hash-ref created 'uid)) #:env env-db) 'ok) #t))

    (test-case "odysseus-research list/show/report/search/delete (filesystem)"
      (seed-research!)
      (define lst (run-json (cli "odysseus-research.rkt") '("list") #:env env-data))
      (check-equal? (map (lambda (r) (hash-ref r 'id)) lst) '("rp2" "rp1"))  ; started_at DESC
      (check-equal? (hash-ref (cadr lst) 'sources) 2)                        ; rp1 source count
      (check-equal? (length (run-json (cli "odysseus-research.rkt")
                            '("list" "--status" "complete") #:env env-data)) 1)  ; complete->done alias
      (define rep (run-json (cli "odysseus-research.rkt") '("report" "rp1") #:env env-data))
      (check-true (regexp-match? #rx"qubits" (hash-ref rep 'report)))
      (define found (run-json (cli "odysseus-research.rkt") '("search" "coffee") #:env env-data))
      (check-equal? (map (lambda (r) (hash-ref r 'id)) found) '("rp2"))
      (check-equal? (hash-ref (run-json (cli "odysseus-research.rkt")
                              '("delete" "rp2") #:env env-data) 'ok) #t)
      (define-values (code _o) (run-cli (cli "odysseus-research.rkt") '("show" "nope") #:env env-data))
      (check-equal? code 1))

    (test-case "domain/notes web shape (HTTP /api/notes drop-in)"
      (seed-rows!)
      (define c (sqlite3-connect #:database db-path #:mode 'read/write))
      (define res (list-notes-web c))
      (check-true (hash-has-key? res 'notes))               ; wrapped {"notes":[...]}
      (define active (hash-ref res 'notes))
      (check-equal? (map (lambda (n) (hash-ref n 'id)) active) '("n1"))  ; archived excluded
      (define n1 (car active))
      (check-equal? (hash-ref n1 'owner) 'null)             ; NULL -> json null (not "")
      (check-true (list? (hash-ref n1 'items)))             ; items JSON parsed
      (check-equal? (hash-ref n1 'image_url) 'null)         ; absent column -> null
      (check-equal? (hash-ref n1 'repeat) "none")           ; NULL -> "none"
      (check-true (string? (hash-ref n1 'created_at)))      ; isoformat string
      (define arch (hash-ref (list-notes-web c #:archived? #t) 'notes))
      (check-equal? (map (lambda (n) (hash-ref n 'id)) arch) '("n2"))
      ;; owner filter (trusted-header identity)
      (query-exec c (string-append
        "INSERT INTO notes(id,title,note_type,owner,pinned,archived,source,sort_order,created_at,updated_at)"
        " VALUES('nb','Bob note','note','bob',0,0,'user',0,"
        "'2026-03-04 09:00:00.000000','2026-03-04 09:00:00.000000')"))
      (check-equal? (map (lambda (n) (hash-ref n 'id))
                         (hash-ref (list-notes-web c #:owner "bob") 'notes)) '("nb"))
      (check-equal? (hash-ref (list-notes-web c #:owner "nobody") 'notes) '())
      (disconnect c))

    (test-case "tool-schema DSL emits OpenAI-compatible schemas"
      (define (fn name) (hash-ref (tool-ref name) 'function))
      (define (params name) (hash-ref (fn name) 'parameters))
      (check-equal? (hash-ref (tool-ref 'bash) 'type) "function")
      (check-equal? (hash-ref (fn 'bash) 'name) "bash")
      ;; required by default; #:optional drops from "required"
      (check-equal? (hash-ref (params 'grep) 'required) '("pattern"))   ; others optional
      (check-equal? (hash-ref (params 'ls) 'required) '())              ; lone optional path
      (check-equal? (hash-ref (params 'edit_file) 'required) '("path" "old_string" "new_string"))
      ;; enum carried through
      (check-equal? (hash-ref (hash-ref (hash-ref (params 'web_search) 'properties) 'time_filter) 'enum)
                    '("day" "week" "month" "year"))
      ;; nested object arrays (#:items-of): items spec with its own properties/required
      (define ci (hash-ref (hash-ref (params 'manage_notes) 'properties) 'checklist_items))
      (check-equal? (hash-ref ci 'type) "array")
      (check-equal? (hash-ref (hash-ref ci 'items) 'type) "object")
      (check-equal? (hash-ref (hash-ref ci 'items) 'required) '("text"))
      (check-equal? (hash-ref (hash-ref (hash-ref (hash-ref ci 'items) 'properties) 'done) 'type)
                    "boolean")
      ;; params without description omit the key entirely (e.g. these actions)
      (check-false (hash-has-key?
                    (hash-ref (hash-ref (params 'manage_tokens) 'properties) 'action) 'description))
      ;; type-less params (manage_settings.value) omit the "type" key
      (check-false (hash-has-key?
                    (hash-ref (hash-ref (params 'manage_settings) 'properties) 'value) 'type))
      (check-equal? (length (all-tool-schemas)) 20))

    (test-case "native function-call → ToolBlock converter"
      (define (conv n a) (function-call->tool-block n a))
      (define (tc n a) (let ([t (conv n a)]) (and t (tool-block-content t))))
      (check-equal? (let ([t (conv "bash" "{\"command\":\"ls -la\"}")])
                      (list (tool-block-type t) (tool-block-content t))) '("bash" "ls -la"))
      (check-equal? (tool-block-type (conv "shell" "{\"command\":\"pwd\"}")) "bash")  ; alias
      (check-false (conv "frobnicate" "{}"))                                          ; unknown
      (check-false (conv "bash" "NOT JSON"))                                          ; bad json
      (check-equal? (tc "bash" "[1,2]") "")                                           ; non-dict → {}
      (check-equal? (tool-block-type (conv "send_email" "{\"to\":\"a\"}")) "mcp__email__send_email")
      ;; web_search query + time_filter → JSON object
      (let ([j (string->jsexpr (tc "web_search" "{\"query\":\"x\",\"time_filter\":\"week\"}"))])
        (check-equal? (hash-ref j 'query) "x")
        (check-equal? (hash-ref j 'time_filter) "week"))
      ;; read_file: plain path vs JSON when a range is requested
      (check-equal? (tc "read_file" "{\"path\":\"a.txt\"}") "a.txt")
      (check-equal? (hash-ref (string->jsexpr (tc "read_file" "{\"path\":\"a.txt\",\"offset\":5}")) 'offset) 5)
      ;; structured assembly
      (check-equal? (tc "edit_document" "{\"edits\":[{\"find\":\"a\",\"replace\":\"b\"}]}")
                    "<<<FIND>>>\na\n<<<REPLACE>>>\nb\n<<<END>>>")
      (check-equal? (tc "manage_memory" "{\"action\":\"add\",\"text\":\"hi\",\"category\":\"fact\"}")
                    "add\nhi\nfact")
      ;; manage_notes: aliased names, JSON-passthrough content (the dumps fallback)
      (check-equal? (tool-block-type (conv "todos" "{\"action\":\"list\"}")) "manage_notes")
      (check-equal? (hash-ref (string->jsexpr (tc "manage_notes" "{\"action\":\"add\",\"title\":\"t\"}")) 'title)
                    "t"))

    (test-case "manage_notes tool — CRUD on notes and checklists"
      (define c (sqlite3-connect #:database 'memory))
      (query-exec c (string-append
        "CREATE TABLE notes(id TEXT PRIMARY KEY,owner TEXT,title TEXT,content TEXT,"
        "items TEXT,note_type TEXT,color TEXT,label TEXT,pinned INT,archived INT,due_date TEXT,"
        "source TEXT,session_id TEXT,sort_order INT,image_url TEXT,repeat TEXT,ai_classification TEXT,"
        "ai_content_hash TEXT,agent_session_id TEXT,created_at TEXT,updated_at TEXT)"))
      (define (run s #:owner [o #f]) (manage-notes c s #:owner o))
      ;; add a checklist (alias `create`); items via checklist_items
      (define r1 (run "{\"action\":\"create\",\"title\":\"Groceries\",\"checklist_items\":[{\"text\":\"milk\"},{\"text\":\"eggs\",\"done\":true}],\"pinned\":true}"))
      (check-equal? (hash-ref r1 'exit_code) 0)
      (check-true (string-prefix? (hash-ref r1 'response) "Note created: \"Groceries\""))
      (define nid (hash-ref r1 'note_id))
      (check-equal? (hash-ref r1 'open_url) (format "/#open=notes&note=~a" nid))
      ;; list: Python's exact line format, including checklist rendering
      (define listing (hash-ref (run "{\"action\":\"list\"}") 'results))
      (check-true (string-contains? listing
                    (format "- [~a] **Groceries** [PINNED] [checklist]" (substring nid 0 8))))
      (check-true (string-contains? listing "  [ ] 0: milk"))
      (check-true (string-contains? listing "  [x] 1: eggs"))
      ;; search: substring over title/content/label/items (query|text|title|content)
      (check-true (string-contains? (hash-ref (run "{\"action\":\"search\",\"query\":\"milk\"}") 'results)
                                    "**Groceries**"))
      (check-equal? (hash-ref (run "{\"action\":\"search\",\"query\":\"zzznope\"}") 'response)
                    "No notes found.")
      ;; view: one note by id prefix, rendered like a one-row list
      (check-true (string-contains?
                    (hash-ref (run (jsexpr->string (hasheq 'action "view" 'id (substring nid 0 8)))) 'results)
                    "**Groceries**"))
      (check-equal? (hash-ref (run "{\"action\":\"view\",\"id\":\"nope404\"}") 'error)
                    "Note 'nope404' not found")
      ;; toggle by 8-char id prefix
      (define r2 (run (jsexpr->string (hasheq 'action "toggle_item" 'id (substring nid 0 8) 'index 0))))
      (check-equal? (hash-ref r2 'response) "Item 'milk' marked done")
      ;; update title + archive; archived notes drop out of the default list
      (run (jsexpr->string (hasheq 'action "update" 'id (substring nid 0 8)
                                   'title "Weekend run" 'archived #t)))
      (check-equal? (hash-ref (run "{\"action\":\"list\"}") 'response) "No notes found.")
      (check-true (string-contains? (hash-ref (run "{\"action\":\"list\",\"archived\":true}") 'results)
                                    "**Weekend run**"))
      ;; duplicate-reminder dedup: normalized title + same due_date → existing id
      (define a1 (run "{\"action\":\"add\",\"title\":\"Call dentist\",\"due_date\":\"2026-06-10T09:00:00\"}"))
      (define a2 (run "{\"action\":\"remind\",\"title\":\"Reminder: call  dentist\",\"due_date\":\"2026-06-10T09:00:00\"}"))
      (check-equal? (hash-ref a2 'duplicate #f) #t)
      (check-equal? (hash-ref a2 'note_id) (hash-ref a1 'note_id))
      ;; owner scoping (#f2a79aa): the lookup query is owner-filtered, so another
      ;; account's note falls into the not-found branch ("Note '<id>' not found").
      (define rb (run "{\"action\":\"add\",\"title\":\"Bobs\"}" #:owner "bob"))
      (define att (run (jsexpr->string (hasheq 'action "delete" 'id (hash-ref rb 'note_id)))
                       #:owner "alice"))
      (check-equal? (hash-ref att 'error) (format "Note '~a' not found" (hash-ref rb 'note_id)))
      ;; SECURITY (#f2a79aa): legacy null-owner rows are NOT shared with an
      ;; authenticated owner, but ARE visible in single-user (no-owner) mode.
      (query-exec c "INSERT INTO notes(id,owner,title,items,pinned,archived) VALUES('nullnote1',NULL,'Legacy',NULL,0,0)")
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "delete" 'id "nullnote1")) #:owner "alice") 'error)
                    "Note 'nullnote1' not found")
      (check-true (string-prefix? (hash-ref (run (jsexpr->string (hasheq 'action "delete" 'id "nullnote1"))) 'response)
                                  "Deleted note"))
      ;; errors: bad JSON, unknown action, missing note — and the text renderer
      (check-equal? (hash-ref (run "{nope") 'error) "Invalid JSON arguments")
      (check-true (string-prefix? (hash-ref (run "{\"action\":\"zap\"}") 'error) "Unknown action: zap"))
      (check-equal? (hash-ref (run "{\"action\":\"delete\",\"id\":\"zzz\"}") 'error) "Note 'zzz' not found")
      (check-equal? (tool-result->text (hasheq 'error "boom" 'exit_code 1)) "**Error:** boom")
      (check-true (string-prefix? (tool-result->text r1) "Note created:"))
      (check-true (string-contains? (tool-result->text r1) "**data:**"))
      (disconnect c))

    (test-case "manage_tasks tool — compute-next-run + CRUD on scheduled tasks"
      ;; date math: fixtures verified against live Python compute_next_run
      ;; (after=2026-06-09 14:30 UTC, a Tuesday)
      (define now (find-seconds 0 30 14 9 6 2026 #f))
      (define (cnr s t [d #f]) (compute-next-run s t d #:now now))
      (check-equal? (cnr "daily" "09:00")      "2026-06-10 09:00:00.000000")  ; past today → tomorrow
      (check-equal? (cnr "daily" "16:00")      "2026-06-09 16:00:00.000000")  ; later today
      (check-equal? (cnr "weekly" "08:00" 0)   "2026-06-15 08:00:00.000000")  ; next Monday
      (check-equal? (cnr "weekly" "18:00" 1)   "2026-06-09 18:00:00.000000")  ; today (Tue), later
      (check-equal? (cnr "monthly" "09:00" 1)  "2026-07-01 09:00:00.000000")  ; 1st passed → next month
      (check-equal? (cnr "monthly" "09:00" 31) "2026-06-30 09:00:00.000000")  ; clamp to short month
      (check-false (cnr "once" "09:00"))                                       ; once: no next run
      (check-false (cnr "daily" "9am"))                                        ; malformed → fail closed
      ;; CRUD
      (define c (sqlite3-connect #:database 'memory))
      (query-exec c (string-append
        "CREATE TABLE scheduled_tasks(id TEXT PRIMARY KEY,owner TEXT,name TEXT,prompt TEXT,"
        "task_type TEXT,action TEXT,schedule TEXT,scheduled_time TEXT,scheduled_day INT,"
        "scheduled_date TEXT,trigger_type TEXT,trigger_event TEXT,trigger_count INT,"
        "trigger_counter INT,next_run TEXT,last_run TEXT,status TEXT,output_target TEXT,"
        "session_id TEXT,model TEXT,endpoint_url TEXT,run_count INT,cron_expression TEXT,"
        "then_task_id TEXT,webhook_token TEXT,crew_member_id TEXT,character_id TEXT,"
        "max_steps INT,email_results INT,notifications_enabled INT,created_at TEXT,updated_at TEXT)"))
      (define (run s #:owner [o #f]) (manage-tasks c s #:owner o))
      (define r1 (run "{\"action\":\"create\",\"prompt\":\"Summarize my day\",\"schedule\":\"daily\",\"scheduled_time\":\"07:30\"}"))
      (check-equal? (hash-ref r1 'exit_code) 0)
      (define tid (hash-ref r1 'task_id))
      (check-true (string-prefix? (hash-ref r1 'response)
                                  "Created task 'Summarize my day'"))  ; name falls back to prompt[:50]
      ;; list: response + serialized tasks array (next_run is iso+Z)
      (define l1 (run "{\"action\":\"list\"}"))
      (check-equal? (hash-ref l1 'response) "Found 1 tasks")
      (define t1 (car (hash-ref l1 'tasks)))
      (check-equal? (hash-ref t1 'task_type) "llm")
      (check-equal? (hash-ref t1 'trigger_type) "schedule")
      (check-true (string-suffix? (hash-ref t1 'next_run) "Z"))
      ;; create validations
      (check-equal? (hash-ref (run "{\"action\":\"create\",\"task_type\":\"research\"}") 'error)
                    "Prompt is required for llm/research tasks")
      (check-equal? (hash-ref (run "{\"action\":\"create\",\"task_type\":\"action\"}") 'error)
                    "action_name is required for action tasks")
      ;; edit: changed-field list, action_name reported as "action"
      (define e1 (run (jsexpr->string (hasheq 'action "edit" 'task_id tid
                                              'name "Digest" 'scheduled_time "06:00"))))
      (check-equal? (hash-ref e1 'response) "Updated task 'Digest': name, scheduled_time")
      ;; pause / resume (resume recomputes next_run for schedule triggers)
      (query-exec c "UPDATE scheduled_tasks SET next_run = NULL WHERE id = ?" tid)
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "pause" 'task_id tid))) 'response)
                    "Task 'Digest' paused")
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "resume" 'task_id tid))) 'response)
                    "Task 'Digest' resumed")
      (check-false (sql-null? (query-value c "SELECT next_run FROM scheduled_tasks WHERE id = ?" tid)))
      ;; run: faithful no-scheduler error
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "run" 'task_id tid))) 'error)
                    "Task scheduler not available")
      ;; owner guard + missing id + delete
      (define rb (run "{\"action\":\"create\",\"prompt\":\"x\"}" #:owner "bob"))
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "delete" 'task_id (hash-ref rb 'task_id)))
                                   #:owner "alice") 'error)
                    "Access denied")
      ;; #5264 regression: a scoped caller must fail CLOSED against an owner-less
      ;; (NULL owner) row — tid was created with owner=#f. Pre-fix this leaked
      ;; cross-tenant edit/run of unowned tasks.
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "edit" 'task_id tid 'name "pwn"))
                                   #:owner "alice") 'error)
                    "Access denied")
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "run" 'task_id tid))
                                   #:owner "alice") 'error)
                    "Access denied")
      (check-equal? (hash-ref (run "{\"action\":\"delete\"}") 'error) "task_id is required for delete")
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "delete" 'task_id tid))) 'response)
                    "Deleted task 'Digest'")
      (disconnect c))

    (test-case "integration tools — manage_{endpoints,mcp,webhooks,tokens}"
      (define c (sqlite3-connect #:database 'memory))
      (query-exec c (string-append
        "CREATE TABLE model_endpoints(id TEXT PRIMARY KEY,name TEXT,base_url TEXT,api_key TEXT,"
        "is_enabled INT,created_at TEXT,updated_at TEXT)"))
      (query-exec c (string-append
        "CREATE TABLE mcp_servers(id TEXT PRIMARY KEY,name TEXT,transport TEXT,command TEXT,"
        "args TEXT,env TEXT,url TEXT,is_enabled INT,created_at TEXT,updated_at TEXT)"))
      (query-exec c (string-append
        "CREATE TABLE webhooks(id TEXT PRIMARY KEY,name TEXT,url TEXT,secret TEXT,events TEXT,"
        "is_active INT,created_at TEXT,updated_at TEXT)"))
      (query-exec c (string-append
        "CREATE TABLE api_tokens(id TEXT PRIMARY KEY,owner TEXT,name TEXT,token_hash TEXT,"
        "token_prefix TEXT,scopes TEXT,is_active INT,created_at TEXT,updated_at TEXT)"))
      ;; endpoints: add requires base_url; enable/disable round-trip
      (check-equal? (hash-ref (manage-endpoints c "{\"action\":\"add\"}") 'error) "base_url is required")
      (define ea (manage-endpoints c "{\"action\":\"add\",\"base_url\":\"https://api.x.ai/v1\"}"))
      (check-true (string-prefix? (hash-ref ea 'response) "Added endpoint 'https://api.x.ai/v1'"))
      (define eid (query-value c "SELECT id FROM model_endpoints"))
      (check-equal? (hash-ref (manage-endpoints c (jsexpr->string (hasheq 'action "disable" 'endpoint_id eid)))
                              'response)
                    "Endpoint 'https://api.x.ai/v1' disabled")
      (define el (manage-endpoints c "{\"action\":\"list\"}"))
      (check-equal? (hash-ref el 'response) "1 endpoints")
      (check-equal? (hash-ref (car (hash-ref el 'endpoints)) 'is_enabled) #f)
      ;; mcp: no-manager list; add validations + stored args/env JSON; enable/disable
      (define ml (manage-mcp c "{\"action\":\"list\"}"))
      (check-equal? (hash-ref ml 'response) "No MCP manager available")   ; Python's no-manager path
      (check-equal? (hash-ref ml 'servers) '())
      (check-equal? (hash-ref (manage-mcp c "{\"action\":\"add\",\"name\":\"fs\"}") 'error)
                    "name and command are required")
      ;; #4433 RCE guard: npx is a package runner → refused on the agent path,
      ;; and crucially NO enabled row is written (would auto-reconnect on restart).
      (check-true (string-contains?
                   (hash-ref (manage-mcp c "{\"action\":\"add\",\"name\":\"fs\",\"command\":\"npx\",\"args\":[\"sfs\"],\"env\":{\"T\":\"1\"}}") 'error)
                   "refused unsafe server registration"))
      (check-equal? (query-value c "SELECT COUNT(*) FROM mcp_servers WHERE name='fs'") 0)
      ;; the canonical payload: command='sh' args=['-c','id'] → refused, no row
      (check-true (string-contains?
                   (hash-ref (manage-mcp c "{\"action\":\"add\",\"name\":\"x\",\"command\":\"sh\",\"args\":[\"-c\",\"id\"]}") 'error)
                   "refused unsafe server registration"))
      (check-equal? (query-value c "SELECT COUNT(*) FROM mcp_servers") 0)
      ;; an operator-allowlisted bare launcher passes and persists args/env JSON
      (putenv "ODYSSEUS_MCP_ALLOWED_COMMANDS" "mcp-server-fs")
      (check-equal? (hash-ref (manage-mcp c "{\"action\":\"add\",\"name\":\"fs\",\"command\":\"mcp-server-fs\",\"args\":[\"sfs\"],\"env\":{\"T\":\"1\"}}")
                              'response)
                    "Added MCP server 'fs' (0 tools)")
      (check-equal? (query-value c "SELECT args FROM mcp_servers WHERE name='fs'") "[\"sfs\"]")
      (putenv "ODYSSEUS_MCP_ALLOWED_COMMANDS" "")
      (check-equal? (hash-ref (manage-mcp c "{\"action\":\"reconnect\",\"server_id\":\"x\"}") 'error)
                    "MCP manager not available")
      ;; webhooks: SSRF + event validation surface Python's error text
      (check-equal? (hash-ref (manage-webhooks c "{\"action\":\"add\",\"url\":\"http://127.0.0.1/h\"}") 'error)
                    "URL must not point to private/internal addresses")
      (check-equal? (hash-ref (manage-webhooks c "{\"action\":\"add\",\"url\":\"ftp://example.com\"}") 'error)
                    "URL must use http or https")
      ;; public IP literal (8.8.8.8) — no DNS, so this stays hermetic under the
      ;; Nix build sandbox; URL passes validation, then events validation fails.
      (check-true (string-prefix?
                   (hash-ref (manage-webhooks c "{\"action\":\"add\",\"url\":\"https://8.8.8.8/h\",\"events\":\"bogus\"}") 'error)
                   "Invalid events: bogus. Allowed:"))
      ;; validators directly (no DNS dependency)
      (check-equal? (validate-events "chat.completed , webhook.test") "chat.completed,webhook.test")
      (check-equal? (with-handlers ([exn:fail? exn-message]) (validate-webhook-url "http://[::1]:9/h"))
                    "validate-webhook-url: URL must not point to private/internal addresses")
      ;; tokens: create is the documented bcrypt refusal; list/delete work
      (query-exec c (string-append
        "INSERT INTO api_tokens(id,name,token_hash,token_prefix,scopes,is_active) "
        "VALUES('t1','CI token','$2b$x','abcd1234','chat',1)"))
      (define tl (manage-tokens c "{\"action\":\"list\"}"))
      (check-equal? (hash-ref tl 'response) "1 API tokens")
      (check-equal? (hash-ref (car (hash-ref tl 'tokens)) 'token_prefix) "abcd1234...")
      (check-true (string-contains? (hash-ref (manage-tokens c "{\"action\":\"create\"}") 'error) "bcrypt"))
      (check-equal? (hash-ref (manage-tokens c "{\"action\":\"delete\",\"token_id\":\"t1\"}") 'response)
                    "Deleted token 'CI token'")
      (disconnect c))

    (test-case "manage_documents + manage_settings tools"
      (define c (sqlite3-connect #:database 'memory))
      (query-exec c (string-append
        "CREATE TABLE documents(id TEXT PRIMARY KEY,session_id TEXT,title TEXT,language TEXT,"
        "current_content TEXT,version_count INT,is_active INT,archived INT,owner TEXT,"
        "created_at TEXT,updated_at TEXT)"))
      (query-exec c (string-append
        "INSERT INTO documents(id,title,language,current_content,is_active,owner,created_at,updated_at)"
        " VALUES('d1','Meeting notes','markdown','# Standup',1,'alice',"
        "'2026-06-01 10:00:00.000000','2026-06-08 10:00:00.000000')"))
      ;; strict owner scoping: no owner → zero rows (Python filters false())
      (check-equal? (hash-ref (manage-documents c "{\"action\":\"list\"}") 'response)
                    "No documents found.")
      (define now (find-seconds 0 0 12 9 6 2026 #f))   ; 2026-06-09 12:00 UTC
      (define l1 (manage-documents c "{\"action\":\"list\"}" #:owner "alice" #:now now))
      (check-true (string-contains? (hash-ref l1 'response)
                    "- [Meeting notes](#document-d1) — markdown, 9 chars, updated 1d ago ← most recent"))
      (check-equal? (hash-ref (manage-documents c "{\"action\":\"list\",\"search\":\"zzz\"}" #:owner "alice")
                              'response)
                    "No documents found matching 'zzz'.")
      ;; read renders the anchor + fenced preview
      (define r1 (manage-documents c "{\"action\":\"read\",\"id\":\"d1\"}" #:owner "alice"))
      (check-true (string-contains? (hash-ref r1 'response) "```markdown\n# Standup\n```"))
      (check-false (hash-ref (hash-ref r1 'document) 'truncated))
      (check-equal? (hash-ref (hash-ref r1 'document) 'offset) 0)
      (check-equal? (hash-ref (hash-ref r1 'document) 'next_offset) 'null)
      ;; #4784 pagination: limit cuts the body and reports next_offset; a follow-up
      ;; read at that offset returns the tail (d1 content = "# Standup", 9 chars).
      (define rp (manage-documents c "{\"action\":\"read\",\"id\":\"d1\",\"limit\":4}" #:owner "alice"))
      (check-true  (hash-ref (hash-ref rp 'document) 'truncated))
      (check-equal? (hash-ref (hash-ref rp 'document) 'offset) 0)
      (check-equal? (hash-ref (hash-ref rp 'document) 'next_offset) 4)
      (check-true  (string-contains? (hash-ref rp 'response) "next_offset=4"))
      (define rp2 (manage-documents c "{\"action\":\"read\",\"id\":\"d1\",\"offset\":4,\"limit\":100}" #:owner "alice"))
      (check-false (hash-ref (hash-ref rp2 'document) 'truncated))
      (check-equal? (hash-ref (hash-ref rp2 'document) 'content) "andup")
      (check-equal? (hash-ref (hash-ref rp2 'document) 'next_offset) 'null)
      ;; delete soft-archives; falls back to most-recent when no id given
      (check-equal? (hash-ref (manage-documents c "{\"action\":\"delete\"}" #:owner "alice") 'response)
                    "Deleted document 'Meeting notes'")
      (check-equal? (query-value c "SELECT is_active FROM documents WHERE id='d1'") 0)
      (check-equal? (hash-ref (manage-documents c "{\"action\":\"tidy\"}" #:owner "alice") 'exit_code) 1)
      ;; settings: file store under a temp dir
      (define sdir (make-temporary-file "odyset~a" 'directory))
      (define spath (build-path sdir "settings.json"))
      (define (st s) (manage-settings c spath s))
      ;; set via friendly alias + endpoint-model resolution machinery (no endpoints table needed
      ;; for non-model keys); bool coercion; enum guard; secret + structured refusals
      (query-exec c (string-append
        "CREATE TABLE model_endpoints(id TEXT PRIMARY KEY,name TEXT,base_url TEXT,api_key TEXT,"
        "is_enabled INT,cached_models TEXT,created_at TEXT,updated_at TEXT)"))
      (check-equal? (hash-ref (st "{\"action\":\"set\",\"key\":\"search engine\",\"value\":\"brave\"}") 'response)
                    "Set search_provider = brave.")
      (check-equal? (hash-ref (st "{\"action\":\"get\",\"key\":\"search engine\"}") 'response)
                    "search_provider = brave")
      (check-equal? (hash-ref (st "{\"action\":\"set\",\"key\":\"tts\",\"value\":\"off\"}") 'response)
                    "Set tts_enabled = False.")
      (check-equal? (hash-ref (st "{\"action\":\"set\",\"key\":\"image quality\",\"value\":\"ultra\"}") 'error)
                    "image_quality must be one of: low, medium, high.")
      (check-true (string-contains? (hash-ref (st "{\"action\":\"set\",\"key\":\"brave_api_key\",\"value\":\"x\"}") 'response)
                                    "credential/secret"))
      (check-true (string-contains? (hash-ref (st "{\"action\":\"set\",\"key\":\"keybinds\",\"value\":\"x\"}") 'response)
                                    "structured setting"))
      ;; model key resolves endpoint+model from cached lists
      (query-exec c (string-append
        "INSERT INTO model_endpoints(id,name,base_url,is_enabled,cached_models) "
        "VALUES('ep1','Local','http://x',1,'[\"qwen2.5:7b-instruct\",\"phi3:latest\"]')"))
      (check-equal? (hash-ref (st "{\"action\":\"set\",\"key\":\"default model\",\"value\":\"qwen 2.5 7b\"}") 'response)
                    "Set default_model = qwen2.5:7b-instruct (endpoint ep1).")
      ;; reset, unknown key, tool toggles
      (check-equal? (hash-ref (st "{\"action\":\"reset\",\"key\":\"search engine\"}") 'response)
                    "Reset search_provider to default (searxng).")
      (check-true (string-prefix? (hash-ref (st "{\"action\":\"get\",\"key\":\"bogus_key\"}") 'error)
                                  "Unknown setting 'bogus_key'."))
      (check-true (string-contains? (hash-ref (st "{\"action\":\"disable_tool\",\"tool\":\"shell\"}") 'response)
                                    "Disabled shell (bash). Now disabled: bash."))
      (check-equal? (hash-ref (st "{\"action\":\"list_tools\"}") 'disabled) '("bash"))
      (check-true (string-contains? (hash-ref (st "{\"action\":\"enable_tool\",\"tool\":\"shell\"}") 'response)
                                    "Now disabled: (none)."))
      ;; #4742: search/web/research each cover BOTH web_search and web_fetch
      (check-true (string-contains? (hash-ref (st "{\"action\":\"disable_tool\",\"tool\":\"search\"}") 'response)
                                    "Disabled search (web_search, web_fetch)"))
      (check-equal? (hash-ref (st "{\"action\":\"list_tools\"}") 'disabled) '("web_search" "web_fetch"))
      (st "{\"action\":\"enable_tool\",\"tool\":\"search\"}")
      ;; #3681: email toggle expands to the full BUILTIN_EMAIL_TOOLS set, both spellings
      (define ed (hash-ref (st "{\"action\":\"disable_tool\",\"tool\":\"email\"}") 'disabled))
      (check-true (and (member "send_email" ed) #t))
      (check-true (and (member "mcp__email__send_email" ed) #t))
      (check-equal? (length ed) 32)
      (st "{\"action\":\"enable_tool\",\"tool\":\"email\"}")
      (delete-directory/files sdir)
      (disconnect c))

    (test-case "manage_skills tool — SKILL.md round-trip + CRUD lifecycle"
      ;; format: parse → emit is stable (same fixture verified byte-identical
      ;; to Python's own from_markdown→to_markdown round-trip)
      (define md (string-join
                  '("---" "name: open-pr-from-branch" "description: Open a GitHub PR"
                    "version: 1.0.0" "category: dev" "tags: [git, github]" "status: published"
                    "confidence: 0.92" "source: learned" "owner: alice"
                    "created: \"2026-06-09T21:43:00Z\"" "---" ""
                    "## When to Use" "" "User asks to open a PR." "" "## Procedure" ""
                    "1. git push -u origin HEAD" "2. gh pr create --fill" "") "\n"))
      (define rt (skill->markdown (skill-from-markdown md)))
      (check-equal? (skill->markdown (skill-from-markdown rt)) rt)   ; fixpoint
      (check-true (string-contains? rt "tags: [git, github]"))
      (check-true (string-contains? rt "created: \"2026-06-09T21:43:00Z\""))  ; quoted (has ':')
      (check-equal? (slugify "Open PR From Branch!") "open-pr-from-branch")
      ;; tool lifecycle on a scratch data dir
      (define dir (make-temporary-file "odysk~a" 'directory))
      (define (run s #:owner [o #f]) (manage-skills dir s #:owner o))
      (check-equal? (hash-ref (run "{\"action\":\"list\"}") 'results)
                    "No skills yet. Create one with action='add'.")
      (define a1 (run "{\"action\":\"add\",\"name\":\"Open PR From Branch\",\"status\":\"draft\",\"description\":\"Open a GitHub PR\",\"category\":\"dev\",\"when_to_use\":\"User asks to open a PR\",\"procedure\":[\"git push -u origin HEAD\",\"gh pr create --fill\"]}"))
      (check-true (string-prefix? (hash-ref a1 'results) "Created skill `open-pr-from-branch`"))
      (check-true (string-contains? (hash-ref a1 'results) "DRAFT"))   ; explicit draft → verify hint
      (check-true (file-exists? (build-path dir "skills" "dev" "open-pr-from-branch" "SKILL.md")))
      ;; #fa8c93e: with no explicit status and auto_approve_skills defaulting on
      ;; (no user_prefs.json here), an add publishes immediately — no DRAFT hint.
      (define apub (run "{\"action\":\"add\",\"name\":\"Auto Pub\",\"description\":\"d\",\"when_to_use\":\"w\",\"procedure\":[\"step\"]}"))
      (check-false (string-contains? (hash-ref apub 'results) "DRAFT"))
      (run "{\"action\":\"delete\",\"name\":\"auto-pub\"}")   ; tidy so it doesn't affect later list/search
      ;; near-duplicate add dedupes instead of creating
      (check-true (string-prefix?
                   (hash-ref (run "{\"action\":\"add\",\"name\":\"open pr from branch\",\"description\":\"Open a GitHub PR now\",\"when_to_use\":\"User asks to open a PR\",\"procedure\":[\"git push -u origin HEAD\",\"gh pr create --fill\"]}")
                             'results)
                   "A near-identical skill already exists: `open-pr-from-branch`"))
      ;; missing procedure/solution is rejected
      (check-true (string-prefix? (hash-ref (run "{\"action\":\"add\",\"name\":\"x\"}") 'error)
                                  "procedure (or solution body) is required"))
      ;; patch: unique replace works, ambiguous old_string is refused
      (check-equal? (hash-ref (run "{\"action\":\"patch\",\"name\":\"open-pr-from-branch\",\"old_string\":\"--fill\",\"new_string\":\"--fill --draft\"}")
                              'results)
                    "Patched skill `open-pr-from-branch`.")
      (check-true (string-contains?
                   (hash-ref (run "{\"action\":\"patch\",\"name\":\"open-pr-from-branch\",\"old_string\":\"r\",\"new_string\":\"R\"}")
                             'error)
                   "ambiguous"))
      ;; publish flips status; search finds it; view returns raw SKILL.md
      (check-true (string-prefix? (hash-ref (run "{\"action\":\"publish\",\"name\":\"open-pr-from-branch\"}") 'results)
                                  "✅ Published"))
      (check-true (string-contains? (hash-ref (run "{\"action\":\"list\"}") 'results) "## Published"))
      (check-true (string-contains? (hash-ref (run "{\"action\":\"search\",\"query\":\"open a github pr\"}") 'results)
                                    "**open-pr-from-branch**"))
      (check-true (string-prefix? (hash-ref (run "{\"action\":\"view\",\"name\":\"open-pr-from-branch\"}") 'results)
                                  "---\nname: open-pr-from-branch"))
      ;; view_ref refuses path traversal
      (check-true (hash-has-key? (run "{\"action\":\"view_ref\",\"name\":\"open-pr-from-branch\",\"path\":\"../../../etc/passwd\"}")
                                 'error))
      ;; owner scoping: alice's skill is invisible to bob (and to unscoped delete)
      (run "{\"action\":\"add\",\"name\":\"alices-skill\",\"procedure\":[\"step\"]}" #:owner "alice")
      (check-true (hash-has-key? (run "{\"action\":\"delete\",\"name\":\"alices-skill\"}" #:owner "bob") 'error))
      (check-equal? (hash-ref (run "{\"action\":\"delete\",\"name\":\"alices-skill\"}" #:owner "alice") 'results)
                    "Deleted skill `alices-skill`.")
      (check-equal? (hash-ref (run "{\"action\":\"delete\",\"name\":\"open-pr-from-branch\"}") 'results)
                    "Deleted skill `open-pr-from-branch`.")
      (check-equal? (hash-ref (run "{\"action\":\"list\"}") 'results)
                    "No skills yet. Create one with action='add'.")
      (delete-directory/files dir))

    (test-case "manage_calendar tool — NL datetimes + event CRUD + reminders"
      ;; datetime engine: fixtures verified identical to live Python _parse_dt /
      ;; parse_due_for_user / _parse_dt_pair at now = Wed 2026-06-10 14:30
      (define now (find-seconds 0 30 14 10 6 2026 #f))
      (define (pd s) (naive->iso (parse-dt s #:now now)))
      (check-equal? (pd "2026-06-15T09:00:00+09:00") "2026-06-15T00:00:00")  ; aware → UTC naive
      (check-equal? (pd "today at 9pm")      "2026-06-10T21:00:00")
      (check-equal? (pd "tomorrow 14:00")    "2026-06-11T14:00:00")
      (check-equal? (pd "next monday at 9am") "2026-06-15T09:00:00")
      (check-equal? (pd "next wednesday")    "2026-06-17T00:00:00")          ; Wed → +7
      (check-equal? (pd "in 45 min")         "2026-06-10T15:15:00")
      (check-equal? (pd "12am")              "2026-06-10T00:00:00")
      (check-equal? (parse-due-for-user "2026-06-15T09:00:00Z" #:now now)
                    "2026-06-15T09:00:00+00:00")
      (define-values (pp pu) (parse-dt-pair "2026-06-15T09:00:00Z" #:now now))
      (check-equal? (list (naive->iso pp) pu) '("2026-06-15T09:00:00" #t))
      ;; CRUD on a scratch DB (utc "now" pretends UTC+1)
      (define c (sqlite3-connect #:database 'memory))
      (query-exec c (string-append
        "CREATE TABLE calendars(id TEXT PRIMARY KEY,owner TEXT,name TEXT,color TEXT,source TEXT,"
        "account_id TEXT,created_at TEXT,updated_at TEXT)"))
      (query-exec c (string-append
        "CREATE TABLE calendar_events(uid TEXT PRIMARY KEY,calendar_id TEXT,summary TEXT,"
        "description TEXT,location TEXT,dtstart TEXT,dtend TEXT,all_day INT,is_utc INT,rrule TEXT,"
        "color TEXT,status TEXT,importance TEXT,event_type TEXT,last_pinged TEXT,"
        "created_at TEXT,updated_at TEXT)"))
      (query-exec c (string-append
        "CREATE TABLE notes(id TEXT PRIMARY KEY,owner TEXT,title TEXT,content TEXT,items TEXT,"
        "note_type TEXT,color TEXT,label TEXT,pinned INT,archived INT,due_date TEXT,source TEXT,"
        "session_id TEXT,sort_order INT,repeat TEXT,created_at TEXT,updated_at TEXT)"))
      (define nu (find-seconds 0 30 13 10 6 2026 #f))
      (define (run s) (manage-calendar c s #:owner "alice" #:now-local now #:now-utc nu))
      ;; list_calendars seeds the default Personal calendar
      (check-true (string-prefix? (hash-ref (run "{\"action\":\"list_calendars\"}") 'response)
                                  "Found 1 calendar(s):"))
      ;; #4266: abbreviated reminder phrasings must parse (longest-first alt so
      ;; "mins"/"hrs" reach past the \b). Direct unit checks on reminder-minutes.
      (check-equal? (reminder-minutes (hasheq 'reminder_minutes "5 mins")) 5)
      (check-equal? (reminder-minutes (hasheq 'reminder_minutes "2 hrs")) 120)
      (check-equal? (reminder-minutes (hasheq 'reminder_minutes "1 hr")) 60)
      (check-equal? (reminder-minutes (hasheq 'reminder_minutes "15 minutes")) 15)  ; long form still works
      (check-equal? (reminder-minutes (hasheq 'reminder_minutes "30m")) 30)         ; bare unit still works
      ;; create with NL start, duration, tag, importance + reminder note
      (define r1 (run "{\"action\":\"create_event\",\"summary\":\"Dentist\",\"dtstart\":\"tomorrow 9am\",\"duration\":\"45m\",\"location\":\"Main St\",\"event_type\":\"health\",\"importance\":\"high\",\"reminder_minutes\":30}"))
      (check-true (string-contains? (hash-ref r1 'response) "Created event [Dentist](#event-"))
      (check-true (string-contains? (hash-ref r1 'response) "[health]"))
      (check-true (string-contains? (hash-ref r1 'response) "with reminder 30 min before"))
      (check-equal? (query-value c "SELECT dtend FROM calendar_events") "2026-06-11 09:45:00.000000")
      (check-equal? (query-row c "SELECT title, due_date FROM notes")
                    #("Reminder: Dentist" "2026-06-11T08:30:00"))
      ;; duplicate create (case-insensitive summary + same start) returns existing uid
      (define r2 (run "{\"action\":\"create\",\"summary\":\"dentist\",\"dtstart\":\"2026-06-11T09:00:00\"}"))
      (check-equal? (hash-ref r2 'duplicate #f) #t)
      (check-equal? (hash-ref r2 'uid) (hash-ref r1 'uid))
      ;; list renders range + anchor + tags
      (define l1 (run "{\"action\":\"list_events\"}"))
      (check-true (string-prefix? (hash-ref l1 'response)
                                  "Found 1 event(s) between 2026-06-10 and 2026-06-24:"))
      (check-true (string-contains? (hash-ref l1 'response) "#health !high @ Main St (Personal)"))
      ;; #5469099: a same-day query (start==end) expands to one day and returns
      ;; that day's events (without the clamp, dtstart<end AND dtend>start at a
      ;; zero-width window matches nothing).
      (define lsd (run "{\"action\":\"list_events\",\"start\":\"2026-06-11\",\"end\":\"2026-06-11\"}"))
      (check-true (string-contains? (hash-ref lsd 'response) "Dentist"))
      ;; update + compound-uid handling + delete
      (define uid (hash-ref r1 'uid))
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "update_event"
                                                           'uid (string-append uid "::20260611")
                                                           'summary "Dentist v2")))
                              'response)
                    (format "Updated event ~a::20260611" uid))
      (check-equal? (query-value c "SELECT summary FROM calendar_events") "Dentist v2")
      (check-equal? (hash-ref (run "{\"action\":\"delete_event\",\"uid\":\"::x\"}") 'error)
                    "malformed compound UID: missing base before ::")
      (check-equal? (hash-ref (run (jsexpr->string (hasheq 'action "delete_event" 'uid uid))) 'response)
                    (format "Deleted event ~a" uid))
      ;; parse failure carries Python's error shape
      (check-true (string-prefix? (hash-ref (run "{\"action\":\"create_event\",\"summary\":\"X\",\"dtstart\":\"someday maybe\"}")
                                            'error)
                                  "Could not parse dtstart 'someday maybe':"))
      ;; #d9a4b99: a batch {"events":[...]} with no action creates each, normalizing
      ;; a Google-style {dateTime:...} start as well as a flat dtstart.
      (define batch (run (string-append
                          "{\"events\":[{\"summary\":\"BatchA\",\"start\":{\"dateTime\":\"2026-06-12T10:00:00\"}},"
                          "{\"summary\":\"BatchB\",\"dtstart\":\"2026-06-12T11:00:00\"}]}")))
      (check-equal? (hash-ref batch 'created_count) 2)
      (check-equal? (hash-ref batch 'failed_count) 0)
      (check-true (string-prefix? (hash-ref batch 'response) "Created 2 event(s):"))
      ;; #4 rrule on update: repeat∈{none,no,off,false,single} OR rrule="" clears;
      ;; an explicit rrule value sets it (was a bug-compatible no-op before).
      (define rr (run "{\"action\":\"create_event\",\"summary\":\"Standup\",\"dtstart\":\"2026-06-13T09:00:00\",\"rrule\":\"FREQ=DAILY\"}"))
      (define ruid (hash-ref rr 'uid))
      (check-equal? (query-value c "SELECT rrule FROM calendar_events WHERE uid = ?" ruid) "FREQ=DAILY")
      (run (jsexpr->string (hasheq 'action "update_event" 'uid ruid 'repeat "single")))
      (check-equal? (query-value c "SELECT rrule FROM calendar_events WHERE uid = ?" ruid) "")  ; repeat=single clears
      (run (jsexpr->string (hasheq 'action "update_event" 'uid ruid 'rrule "FREQ=WEEKLY")))
      (check-equal? (query-value c "SELECT rrule FROM calendar_events WHERE uid = ?" ruid) "FREQ=WEEKLY")  ; explicit sets
      (run (jsexpr->string (hasheq 'action "update_event" 'uid ruid 'rrule "")))
      (check-equal? (query-value c "SELECT rrule FROM calendar_events WHERE uid = ?" ruid) "")  ; empty string clears
      ;; #4 start_time/end_time aliases resolve the list window
      (check-true (string-contains?
                    (hash-ref (run "{\"action\":\"list_events\",\"start_time\":\"2026-06-13\",\"end_time\":\"2026-06-14\"}") 'response)
                    "Standup"))
      ;; #4 a vague NL range (query/date_range/range) without explicit start+end is rejected
      (check-true (string-prefix?
                    (hash-ref (run "{\"action\":\"list_events\",\"query\":\"next week\"}") 'error)
                    "list_events needs explicit start/end ISO datetimes"))
      (disconnect c))

    (test-case "review regressions — Python-truthiness & fidelity fixes"
      ;; (A) calendar reminder_minutes=0 means NO reminder (Python's falsy `or`),
      ;; and event_type:\"\" falls through to tag (not 'clear to NULL')
      (define cc (sqlite3-connect #:database 'memory))
      (query-exec cc (string-append
        "CREATE TABLE calendars(id TEXT PRIMARY KEY,owner TEXT,name TEXT,color TEXT,source TEXT,"
        "account_id TEXT,created_at TEXT,updated_at TEXT)"))
      (query-exec cc (string-append
        "CREATE TABLE calendar_events(uid TEXT PRIMARY KEY,calendar_id TEXT,summary TEXT,"
        "description TEXT,location TEXT,dtstart TEXT,dtend TEXT,all_day INT,is_utc INT,rrule TEXT,"
        "color TEXT,status TEXT,importance TEXT,event_type TEXT,last_pinged TEXT,created_at TEXT,updated_at TEXT)"))
      (query-exec cc (string-append
        "CREATE TABLE notes(id TEXT PRIMARY KEY,owner TEXT,title TEXT,content TEXT,items TEXT,"
        "note_type TEXT,color TEXT,label TEXT,pinned INT,archived INT,due_date TEXT,source TEXT,"
        "session_id TEXT,sort_order INT,repeat TEXT,created_at TEXT,updated_at TEXT)"))
      (define cnow (find-seconds 0 30 14 10 6 2026 #f))
      (define (cal s) (manage-calendar cc s #:owner "alice" #:now-local cnow #:now-utc cnow))
      (define r0 (cal "{\"action\":\"create_event\",\"summary\":\"NoRemind\",\"dtstart\":\"tomorrow 9am\",\"reminder_minutes\":0,\"event_type\":\"\",\"tag\":\"work\"}"))
      (check-false (string-contains? (hash-ref r0 'response) "reminder"))   ; reminder_minutes 0 → none
      (check-equal? (hash-ref r0 'reminder_note_id) 'null)
      (check-equal? (query-value cc "SELECT count(*) FROM notes") 0)        ; no reminder note created
      (check-equal? (query-value cc "SELECT event_type FROM calendar_events WHERE summary='NoRemind'")
                    "work")                                                 ; event_type:'' fell through to tag
      ;; aware dtend folds is_utc onto the event even when dtstart is naive
      (cal "{\"action\":\"create_event\",\"summary\":\"TZ\",\"dtstart\":\"2026-06-20T10:00:00\",\"dtend\":\"2026-06-20T15:00:00Z\"}")
      (check-equal? (query-value cc "SELECT is_utc FROM calendar_events WHERE summary='TZ'") 1)
      ;; update event_type:'' + tag:'work' sets work (not NULL)
      (define tzuid (query-value cc "SELECT uid FROM calendar_events WHERE summary='TZ'"))
      (cal (jsexpr->string (hasheq 'action "update_event" 'uid tzuid 'event_type "" 'tag "work")))
      (check-equal? (query-value cc "SELECT event_type FROM calendar_events WHERE uid=?" tzuid) "work")
      (disconnect cc)
      ;; (B) notes due_date is parsed (NL → ISO), not stored verbatim
      (define nc (sqlite3-connect #:database 'memory))
      (query-exec nc (string-append
        "CREATE TABLE notes(id TEXT PRIMARY KEY,owner TEXT,title TEXT,content TEXT,items TEXT,"
        "note_type TEXT,color TEXT,label TEXT,pinned INT,archived INT,due_date TEXT,source TEXT,"
        "session_id TEXT,sort_order INT,repeat TEXT,created_at TEXT,updated_at TEXT)"))
      (manage-notes nc "{\"action\":\"add\",\"title\":\"Call\",\"due_date\":\"tomorrow at 9am\"}")
      (check-true (regexp-match? #px"T09:00:00$" (query-value nc "SELECT due_date FROM notes WHERE title='Call'")))
      ;; toggle_item rejects a non-numeric index instead of silently toggling item 0
      (define ra (manage-notes nc "{\"action\":\"add\",\"title\":\"L\",\"checklist_items\":[{\"text\":\"a\"},{\"text\":\"b\"}]}"))
      (define nid8 (substring (hash-ref ra 'note_id) 0 8))
      (check-true (string-prefix? (hash-ref (manage-notes nc (jsexpr->string (hasheq 'action "toggle_item" 'id nid8 'index "x"))) 'error)
                                  "Invalid item index"))
      (check-equal? (hash-ref (manage-notes nc (jsexpr->string (hasheq 'action "toggle_item" 'id nid8 'index "1"))) 'response)
                    "Item 'b' marked done")          ; numeric string still works
      (disconnect nc)
      ;; (C) tool-result->text caps the data block at 8000 chars (Python parity)
      (define big (make-string 9000 #\x))
      (define rendered (tool-result->text (hasheq 'response "ok" 'blob big)))
      (check-true (< (string-length rendered) 8300))
      (check-true (string-contains? rendered "truncated, "))
      ;; (D) settings coerce accepts a float-typed JSON int (int(5.0)=5)
      (define sc (sqlite3-connect #:database 'memory))
      (query-exec sc "CREATE TABLE model_endpoints(id TEXT,cached_models TEXT,is_enabled INT)")
      (define sdir (make-temporary-file "odyrr~a" 'directory))
      (define spath (build-path sdir "settings.json"))
      (check-equal? (hash-ref (manage-settings sc spath "{\"action\":\"set\",\"key\":\"search_result_count\",\"value\":5.0}") 'response)
                    "Set search_result_count = 5.")
      (delete-directory/files sdir)
      (disconnect sc))

    (test-case "agent loop — control spine (done / tools / max-rounds)"
      (define exec-log (box '()))
      (define (exec b) (set-box! exec-log (cons (tool-block-type b) (unbox exec-log))) "RESULT")
      ;; a scripted llm that yields the next canned assistant-msg each round and
      ;; records the messages it was handed (so we can inspect protocol threading)
      (define seen (box '()))
      (define (scripted xs) (let ([b (box xs)])
                              (lambda (ms) (set-box! seen (cons ms (unbox seen)))
                                (define m (car (unbox b))) (set-box! b (cdr (unbox b))) m)))
      ;; 1) no tool calls → DONE on round 1
      (define r1 (run-agent '() #:llm (lambda (_) (assistant-msg "hello" '() '())) #:exec exec))
      (check-equal? (agent-result-status r1) 'done)
      (check-equal? (agent-result-rounds r1) 1)
      ;; 2) one tool round, then DONE — with raw tool_calls, the loop must feed
      ;; results back as the real OpenAI protocol (assistant.tool_calls + role:tool)
      (set-box! exec-log '()) (set-box! seen '())
      (define bash (function-call->tool-block "bash" "{\"command\":\"ls\"}"))
      (define raw (hasheq 'id "call_abc" 'type "function"
                          'function (hasheq 'name "bash" 'arguments "{\"command\":\"ls\"}")))
      (define r2 (run-agent '() #:exec exec
                            #:llm (scripted (list (assistant-msg "" (list bash) (list raw))
                                                  (assistant-msg "Done." '() '())))))
      (check-equal? (agent-result-status r2) 'done)
      (check-equal? (agent-result-rounds r2) 2)
      (check-equal? (unbox exec-log) '("bash"))          ; tool executed once
      (check-equal? (length (agent-result-transcript r2)) 3)  ; assistant, tools, assistant
      ;; the 2nd llm turn received: assistant w/ tool_calls, then role:tool w/ id
      (define round2-msgs (car (unbox seen)))            ; most recent call
      (define a-msg (findf (lambda (m) (and (equal? (hash-ref m 'role #f) "assistant")
                                            (hash-has-key? m 'tool_calls))) round2-msgs))
      (define t-msg (findf (lambda (m) (equal? (hash-ref m 'role #f) "tool")) round2-msgs))
      (check-true (and a-msg #t) "assistant turn echoes tool_calls")
      (check-true (and t-msg #t) "result fed back as a role:tool message")
      (check-equal? (hash-ref t-msg 'tool_call_id) "call_abc")
      (check-equal? (hash-ref t-msg 'content) "RESULT")
      ;; 3) never stops → MAX-ROUNDS
      (define r3 (run-agent '() #:exec exec #:max-rounds 3
                            #:llm (lambda (_) (assistant-msg "" (list bash) (list raw)))))
      (check-equal? (agent-result-status r3) 'max-rounds)
      (check-equal? (agent-result-rounds r3) 3))

    (test-case "agent loop — #1629 non-native tool results wrapped untrusted + wire scrub"
      (define (exec b) "TOOLOUT")
      (define seen (box '()))
      (define (scripted xs) (let ([b (box xs)])
                              (lambda (ms) (set-box! seen (cons ms (unbox seen)))
                                (define m (car (unbox b))) (set-box! b (cdr (unbox b))) m)))
      (define bash (function-call->tool-block "bash" "{\"command\":\"ls\"}"))
      ;; NON-native path: tool-blocks present but NO raw tool_calls → prompted
      ;; fallback (what models without native tool-calling use).
      (run-agent '() #:exec exec
                 #:llm (scripted (list (assistant-msg "" (list bash) '())
                                       (assistant-msg "Done." '() '()))))
      (define round2 (car (unbox seen)))
      (define wrap (findf (lambda (m) (and (equal? (hash-ref m 'role #f) "user")
                                           (hash-has-key? m 'metadata))) round2))
      (check-true (and wrap #t) "non-native tool result fed back as a wrapped user turn")
      ;; SECURITY (#1629): prompt-injection in tool output must be data, not
      ;; instructions — metadata.trusted=#f + the untrusted-source envelope.
      (check-equal? (hash-ref (hash-ref wrap 'metadata) 'trusted) #f)
      (check-true (string-contains? (hash-ref wrap 'content) "UNTRUSTED SOURCE DATA"))
      (check-true (string-contains? (hash-ref wrap 'content) "Source: tool execution results"))
      (check-true (string-contains? (hash-ref wrap 'content) "TOOLOUT"))
      ;; the internal metadata key must be scrubbed before it reaches a provider
      (define wired (car (sanitize-wire-messages (list wrap))))
      (check-false (hash-has-key? wired 'metadata))
      (check-true (hash-has-key? wired 'content)))

    (test-case "agent adapter — OpenAI response parse + tool dispatch"
      ;; parse a response carrying a native tool_call
      (define resp (hasheq 'choices
        (list (hasheq 'message
          (hasheq 'content 'null
                  'tool_calls (list (hasheq 'function (hasheq 'name "bash"
                                                             'arguments "{\"command\":\"echo hi\"}"))))))))
      (define m (chat-response->assistant-msg resp))
      (check-equal? (assistant-msg-text m) "")
      (check-equal? (length (assistant-msg-tool-blocks m)) 1)
      (check-equal? (tool-block-content (car (assistant-msg-tool-blocks m))) "echo hi")
      ;; parse a plain final answer (no tools)
      (define m2 (chat-response->assistant-msg
                  (hasheq 'choices (list (hasheq 'message (hasheq 'content "final answer"))))))
      (check-equal? (assistant-msg-text m2) "final answer")
      (check-equal? (assistant-msg-tool-blocks m2) '())
      ;; dispatcher built-ins (pure/portable: read/ls/glob/grep/edit_file)
      (define ex (make-exec))
      (define dir (make-temporary-file "odytest~a" 'directory))
      (define f (build-path dir "x.txt"))
      (call-with-output-file f #:exists 'replace (lambda (o) (display "alpha\nbeta\nGAMMA\nalpha\n" o)))
      (define (path-of p) (path->string p))
      ;; read_file (plain path) and a line range
      (check-equal? (ex (function-call->tool-block "read_file" (jsexpr->string (hasheq 'path (path-of f)))))
                    "alpha\nbeta\nGAMMA\nalpha\n")
      (check-equal? (ex (function-call->tool-block "read_file"
                          (jsexpr->string (hasheq 'path (path-of f) 'offset 2 'limit 1)))) "beta")
      ;; ls + glob find the file
      (check-true (string-contains? (ex (function-call->tool-block "ls" (jsexpr->string (hasheq 'path (path-of dir))))) "x.txt"))
      (check-true (string-contains? (ex (function-call->tool-block "glob"
                    (jsexpr->string (hasheq 'pattern "*.txt" 'path (path-of dir))))) "x.txt"))
      ;; grep → file:line:match
      (check-true (regexp-match? #rx"x.txt:3:GAMMA"
                   (ex (function-call->tool-block "grep" (jsexpr->string (hasheq 'pattern "GAM" 'path (path-of dir)))))))
      ;; edit_file: non-unique without replace_all → error; replace_all → applied
      (check-true (regexp-match? #rx"not unique"
                   (ex (function-call->tool-block "edit_file"
                        (jsexpr->string (hasheq 'path (path-of f) 'old_string "alpha" 'new_string "A"))))))
      (ex (function-call->tool-block "edit_file"
            (jsexpr->string (hasheq 'path (path-of f) 'old_string "alpha" 'new_string "A" 'replace_all #t))))
      (check-equal? (file->string f) "A\nbeta\nGAMMA\nA\n")
      ;; a tool in tool-tags but with no exec handler → "not implemented"
      (check-true (regexp-match? #rx"not implemented"
                   (ex (function-call->tool-block "manage_memory" "{\"action\":\"list\"}"))))
      ;; output-cap fidelity (src/constants.py): read_file caps at
      ;; MAX_READ_CHARS=20000 with "[truncated at N chars]"; bash/python/web/grep/
      ;; glob at MAX_OUTPUT_CHARS=10000 with "(truncated, N chars total)".
      (define bigf (build-path dir "big.txt"))
      (call-with-output-file bigf #:exists 'replace (lambda (o) (display (make-string 20500 #\z) o)))
      (define rf (ex (function-call->tool-block "read_file" (jsexpr->string (hasheq 'path (path-of bigf))))))
      (check-equal? (string-length rf) 20031)                                ; 20000 + message
      (check-true (string-suffix? rf "\n... [truncated at 20000 chars]"))
      (check-equal? (string-length (truncate-output (make-string 10500 #\x))) 10035)  ; 10000 + msg
      (check-true (string-suffix? (truncate-output (make-string 10500 #\x))
                                  "\n... (truncated, 10500 chars total)"))
      ;; ---- file-tool security: deny-list + skip-dirs + confinement
      ;; (#5010/#5011/#5094/#5189/#4538) ----
      ;; unit: _is_sensitive_path port — case-insensitive on dir AND filename
      (check-true  (sensitive-path? "/home/u/.ssh/id_rsa"))
      (check-true  (sensitive-path? "/x/.SSH/AUTHORIZED_KEYS"))   ; case-insensitive
      (check-true  (sensitive-path? "/proj/.env"))
      (check-false (sensitive-path? "/proj/src/main.rkt"))
      ;; fixtures: a secret file, a secret dir, and a skip-dir
      (make-directory* (build-path dir ".ssh"))
      (call-with-output-file (build-path dir ".ssh" "id_rsa") #:exists 'replace
        (lambda (o) (display "PRIVATE-KEY-SECRETVAL\n" o)))
      (call-with-output-file (build-path dir ".env") #:exists 'replace
        (lambda (o) (display "API_TOKEN=SECRETVAL\n" o)))
      (make-directory* (build-path dir "node_modules"))
      (call-with-output-file (build-path dir "node_modules" "junk.js") #:exists 'replace
        (lambda (o) (display "SECRETVAL\n" o)))
      ;; read_file / edit_file refuse a sensitive path
      (check-true (regexp-match? #rx"sensitive file denied"
                   (ex (function-call->tool-block "read_file"
                        (jsexpr->string (hasheq 'path (path-of (build-path dir ".env"))))))))
      (check-true (regexp-match? #rx"sensitive file denied"
                   (ex (function-call->tool-block "edit_file"
                        (jsexpr->string (hasheq 'path (path-of (build-path dir ".ssh" "id_rsa"))
                                                'old_string "x" 'new_string "y"))))))
      ;; glob **/* skips the secret file, the secret dir's contents, node_modules
      (define gsec (ex (function-call->tool-block "glob"
                         (jsexpr->string (hasheq 'pattern "**/*" 'path (path-of dir))))))
      (check-true  (string-contains? gsec "x.txt"))
      (check-false (string-contains? gsec "id_rsa"))
      (check-false (string-contains? gsec ".env"))
      (check-false (string-contains? gsec "junk.js"))            ; node_modules pruned
      ;; grep never reads inside a sensitive file or a skip-dir: SECRETVAL lives
      ;; only in .env, .ssh/id_rsa, and node_modules — all excluded.
      (check-equal? (ex (function-call->tool-block "grep"
                          (jsexpr->string (hasheq 'pattern "SECRETVAL" 'path (path-of dir)))))
                    "(no matches)")
      ;; glob literal can't escape the search root via ../ (path-oracle guard)
      (check-equal? (ex (function-call->tool-block "glob"
                          (jsexpr->string (hasheq 'pattern "../x.txt" 'path (path-of dir)))))
                    "(no matches)")
      ;; ---- #3955 web_fetch download budget ----
      (check-equal? (web-fetch-budget #f #f) 2000000)        ; default soft cap
      (check-equal? (web-fetch-budget #t #f) 20000000)       ; full → hard cap
      (check-equal? (web-fetch-budget #f 500) 500)           ; explicit max_bytes
      (check-equal? (web-fetch-budget #f 99999999) 20000000) ; clamped to hard cap
      (check-equal? (web-fetch-budget #t 500) 500)           ; max_bytes overrides full
      ;; budget cutoff → leading [partial content] notice, Source header, body cut
      (define wtrunc (web-fetch-output #"hello world body" 5 "http://ex"))
      (check-true (string-prefix? wtrunc "[partial content: download stopped at 5 bytes."))
      (check-true (string-contains? wtrunc "Source: http://ex"))
      (check-true (string-contains? wtrunc "hello"))
      (check-false (string-contains? wtrunc "world"))        ; body cut at the budget
      ;; under budget → no notice, just Source + body
      (check-equal? (web-fetch-output #"hi there" 100 "http://ex") "Source: http://ex\n\nhi there")
      ;; empty body → error
      (check-true (string-contains? (web-fetch-output #"" 100 "http://ex") "no readable text content"))
      (delete-directory/files dir))

    (test-case "system-prompt assembly (enabled tools only)"
      (define p (assemble-prompt #:tools '("bash" "read_file")))
      (check-true (string-contains? p "DECLARE WHEN THE JOB IS DONE"))   ; base
      (check-true (string-contains? p "`bash`"))                          ; enabled tool
      (check-true (string-contains? p "`read_file`"))
      (check-false (string-contains? p "`python`"))                       ; not enabled
      ;; disabled filter + compact mode
      (define p2 (assemble-prompt #:tools '("bash" "grep") #:disabled (set "grep")))
      (check-true (string-contains? p2 "`bash`"))
      (check-false (string-contains? p2 "`grep`"))
      (check-true (string-contains? (assemble-prompt #:tools '("bash" "ls") #:compact? #t)
                                    "Available tools: bash, ls")))

    (test-case "streaming — reassemble SSE deltas into an assistant-msg"
      ;; content split across chunks; a tool_call whose name + arguments arrive in pieces
      (define deltas
        (list (hasheq 'content "Hel")
              (hasheq 'content "lo")
              (hasheq 'tool_calls (list (hasheq 'index 0 'function (hasheq 'name "bash" 'arguments "{\"comm"))))
              (hasheq 'tool_calls (list (hasheq 'index 0 'function (hasheq 'arguments "and\":\"ls\"}"))))))
      (define m (stream-deltas->assistant-msg deltas))
      (check-equal? (assistant-msg-text m) "Hello")
      (check-equal? (length (assistant-msg-tool-blocks m)) 1)
      (check-equal? (tool-block-type (car (assistant-msg-tool-blocks m))) "bash")
      (check-equal? (tool-block-content (car (assistant-msg-tool-blocks m))) "ls"))))

(module+ main
  (define n (run-tests suite))
  (delete-directory/files tmp #:must-exist? #f)
  (exit (if (= n 0) 0 1)))
