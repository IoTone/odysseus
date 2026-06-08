#lang racket/base

;; test/seed-db.rkt — create the app schema + sample rows in a SQLite DB so the
;; DB-backed CLIs and HTTP routes can be exercised by hand WITHOUT running the
;; Python app first. (The Racket port consumes the app's DB; it doesn't own the
;; DDL — so on a fresh machine the tables don't exist yet. This seeds them.)
;;
;;   racket test/seed-db.rkt                      # -> ./data/app.db (repo default)
;;   DATABASE_URL=sqlite:///tmp/x.db racket test/seed-db.rkt
;;
;; Idempotent: CREATE TABLE IF NOT EXISTS + INSERT OR IGNORE with fixed ids, so
;; re-running is safe and it won't clobber an existing app DB's real data.

(require db
         db-kit
         "../config.rkt")

(define PNG  ; a real 1x1 PNG as a data URL
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=")

(define (x c sql . args) (apply query-exec c sql args))

(define (seed c)
  ;; notes (full column set used by CLI + web route)
  (x c (string-append
    "CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY,owner TEXT,title TEXT,content TEXT,"
    "items TEXT,note_type TEXT,color TEXT,label TEXT,pinned INT,archived INT,due_date TEXT,"
    "source TEXT,session_id TEXT,sort_order INT,image_url TEXT,repeat TEXT,ai_classification TEXT,"
    "ai_content_hash TEXT,agent_session_id TEXT,created_at TEXT,updated_at TEXT)"))
  (x c (string-append
    "INSERT OR IGNORE INTO notes(id,title,content,items,note_type,label,pinned,archived,source,"
    "sort_order,owner,created_at,updated_at) VALUES('seed-note-1','Buy milk','2%','"
    "[{\"text\":\"milk\",\"done\":false}]','checklist','home',1,0,'user',0,NULL,"
    "'2026-06-01 09:00:00.000000','2026-06-01 09:00:00.000000')"))
  (x c (string-append
    "INSERT OR IGNORE INTO notes(id,title,content,note_type,pinned,archived,source,sort_order,owner,"
    "created_at,updated_at) VALUES('seed-note-2','Bob private','x','note',0,0,'user',0,'bob',"
    "'2026-06-02 09:00:00.000000','2026-06-02 09:00:00.000000')"))
  ;; sessions
  (x c (string-append
    "CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,name TEXT,model TEXT,endpoint_url TEXT,"
    "owner TEXT,folder TEXT,archived INT,rag INT,is_important INT,message_count INT,"
    "total_input_tokens INT,total_output_tokens INT,last_accessed TEXT,created_at TEXT)"))
  (x c (string-append
    "INSERT OR IGNORE INTO sessions VALUES('seed-sess-1','Demo chat','gpt','http://x','alice','work',"
    "0,1,0,3,50,80,'2026-06-05 12:00:00.000000','2026-06-01 08:00:00.000000')"))
  ;; scheduled_tasks + task_runs
  (x c (string-append
    "CREATE TABLE IF NOT EXISTS scheduled_tasks(id TEXT PRIMARY KEY,name TEXT,task_type TEXT,"
    "action TEXT,prompt TEXT,schedule TEXT,scheduled_time TEXT,next_run TEXT,last_run TEXT,status TEXT,"
    "model TEXT,run_count INT,cron_expression TEXT,endpoint_url TEXT,session_id TEXT,webhook_token TEXT)"))
  (x c (string-append
    "INSERT OR IGNORE INTO scheduled_tasks(id,name,task_type,prompt,schedule,scheduled_time,next_run,"
    "status,model,run_count,webhook_token) VALUES('seed-task-1','Nightly digest','llm',"
    "'Summarize today','daily','02:00','2026-06-10 02:00:00.000000','active','gpt',2,'tok')"))
  (x c (string-append
    "CREATE TABLE IF NOT EXISTS task_runs(id TEXT PRIMARY KEY,task_id TEXT,started_at TEXT,"
    "finished_at TEXT,status TEXT,result TEXT)"))
  (x c (string-append
    "INSERT OR IGNORE INTO task_runs VALUES('seed-run-1','seed-task-1','2026-06-09 02:00:00.000000',"
    "'2026-06-09 02:00:07.000000','success','digest sent')"))
  ;; signatures
  (x c (string-append
    "CREATE TABLE IF NOT EXISTS signatures(id TEXT PRIMARY KEY,owner TEXT,name TEXT,width INT,"
    "height INT,data_png TEXT,svg TEXT,created_at TEXT)"))
  (x c "INSERT OR IGNORE INTO signatures VALUES('seed-sig-1','alice','Alice',200,80,?,'<svg/>','2026-06-01 00:00:00.000000')" PNG)
  ;; mcp_servers
  (x c (string-append
    "CREATE TABLE IF NOT EXISTS mcp_servers(id TEXT PRIMARY KEY,name TEXT,transport TEXT,command TEXT,"
    "args TEXT,env TEXT,url TEXT,is_enabled INT,oauth_config TEXT,created_at TEXT)"))
  (x c (string-append
    "INSERT OR IGNORE INTO mcp_servers VALUES('seed-mcp-1','Filesystem','stdio','npx',"
    "'[\"server-fs\",\"/tmp\"]','{\"TOKEN\":\"secret\"}',NULL,1,NULL,'2026-06-01 00:00:00.000000')"))
  ;; calendars + events
  (x c "CREATE TABLE IF NOT EXISTS calendars(id TEXT PRIMARY KEY,name TEXT,color TEXT,source TEXT,created_at TEXT)")
  (x c "INSERT OR IGNORE INTO calendars VALUES('seed-cal-1','Personal','#5b8abf','local','2026-01-01 00:00:00.000000')")
  (x c (string-append
    "CREATE TABLE IF NOT EXISTS calendar_events(uid TEXT PRIMARY KEY,calendar_id TEXT,summary TEXT,"
    "description TEXT,location TEXT,dtstart TEXT,dtend TEXT,all_day INT,is_utc INT,rrule TEXT,color TEXT,"
    "status TEXT,importance TEXT,event_type TEXT,created_at TEXT,updated_at TEXT)"))
  (x c (string-append
    "INSERT OR IGNORE INTO calendar_events VALUES('seed-ev-1','seed-cal-1','Lunch','','',"
    "'2026-06-10 12:00:00.000000','2026-06-10 13:00:00.000000',0,0,'','','confirmed','normal',NULL,"
    "'2026-06-01 00:00:00.000000','2026-06-01 00:00:00.000000')")))

(module+ main
  (define path (sqlite-path (database-url) #:base-dir repo-root))
  (call-with-sqlite path seed #:create-missing? #t)
  (printf "seeded ~a\n" path)
  (printf "  notes(2: 1 owned by bob), sessions(1), scheduled_tasks(1)+task_runs(1),\n")
  (printf "  signatures(1), mcp_servers(1), calendars(1)+calendar_events(1)\n"))
