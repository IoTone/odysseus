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
         "../domain/tools/dsl.rkt"        ; tool-schema DSL
         "../domain/tools/core-tools.rkt"    ; registers the ported tools on load
         "../domain/tools/convert.rkt")      ; native-call → ToolBlock converter

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
      (check-equal? (length (all-tool-schemas)) 10))

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
                    "add\nhi\nfact"))))

(module+ main
  (define n (run-tests suite))
  (delete-directory/files tmp #:must-exist? #f)
  (exit (if (= n 0) 0 1)))
