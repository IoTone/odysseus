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
         db)

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
    "session_id TEXT,sort_order INT,created_at TEXT,updated_at TEXT)"))
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
  (disconnect c))

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
      (check-equal? (hash-ref (cadr runs) 'completed_at) ""))))       ; r2 finished_at NULL

(module+ main
  (define n (run-tests suite))
  (delete-directory/files tmp #:must-exist? #f)
  (exit (if (= n 0) 0 1)))
