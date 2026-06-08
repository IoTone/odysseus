#lang racket/base

;; odysseus-tasks — scheduled tasks + run history (raw SQL via db-kit).
;; Faithful Racket port of scripts/odysseus-tasks.
;;
;;   odysseus-tasks list [--status active|paused|completed] [--limit N]
;;   odysseus-tasks show TASK_ID
;;   odysseus-tasks pause|resume TASK_ID
;;   odysseus-tasks runs [--task TASK_ID] [--limit N]
;;
;; NOTE: the Python original's _serialize_run reads r.completed_at / r.output,
;; which don't exist on the TaskRun model (real columns: finished_at / result) —
;; a latent bug. We keep the intended output keys (completed_at, output_preview)
;; but source them from the real columns.

(require db
         racket/string
         cli-kit
         db-kit
         "../config.rkt")

(define task-cols
  (string-append "id,name,task_type,action,prompt,schedule,scheduled_time,"
                 "next_run,last_run,status,model,run_count,cron_expression"))

(define (preview v)
  (define s (if (string? v) v ""))
  (if (> (string-length s) 200) (string-append (substring s 0 200) "…") s))

(define (serialize-task r)
  (hasheq 'id              (sql-or-null (vector-ref r 0))
          'name            (sql-or-null (vector-ref r 1))
          'task_type       (sql-or-null (vector-ref r 2))
          'action          (sql-or-null (vector-ref r 3))
          'prompt          (preview (vector-ref r 4))
          'schedule        (sql-or-null (vector-ref r 5))
          'scheduled_time  (sql-or-null (vector-ref r 6))
          'next_run        (sqlite-datetime->iso (vector-ref r 7))
          'last_run        (sqlite-datetime->iso (vector-ref r 8))
          'status          (sql-or-null (vector-ref r 9))
          'model           (sql-or-null (vector-ref r 10))
          'run_count       (sql->int (vector-ref r 11))
          'cron_expression (sql-or-empty (vector-ref r 12))))

;; task_runs row: id,task_id,started_at,finished_at,status,result
(define (serialize-run r)
  (hasheq 'id             (vector-ref r 0)
          'task_id        (vector-ref r 1)
          'started_at     (sqlite-datetime->iso (vector-ref r 2))
          'completed_at   (sqlite-datetime->iso (vector-ref r 3))   ; finished_at
          'status         (sql-or-null (vector-ref r 4))
          'output_preview (preview (vector-ref r 5))))              ; result

(define run-cols "id,task_id,started_at,finished_at,status,result")

;; ---- subcommands -----------------------------------------------------------

(define (cmd-list status limit pretty?)
  (define where (if status "WHERE status = ? " ""))
  (define params (if status (list status) '()))
  (define sql (string-append "SELECT " task-cols " FROM scheduled_tasks " where
                             "ORDER BY next_run IS NULL ASC, next_run ASC LIMIT ?"))
  (define rows (call-with-app-db #:mode 'read-only
                 (lambda (c) (apply query-rows c sql (append params (list limit))))))
  (emit (map serialize-task rows) #:pretty? pretty?))

(define (cmd-show id pretty?)
  (define out
    (call-with-app-db #:mode 'read-only
      (lambda (c)
        (define rs (query-rows c
          (string-append "SELECT " task-cols ",prompt,endpoint_url,session_id,webhook_token "
                         "FROM scheduled_tasks WHERE id = ?") id))
        (unless (pair? rs) (fail (format "no task with id ~s" id)))
        (define r (car rs))
        (define base (serialize-task r))
        (define runs (query-rows c
          (string-append "SELECT " run-cols " FROM task_runs WHERE task_id = ? "
                         "ORDER BY started_at DESC LIMIT 5") id))
        (hash-set* base
                   'prompt_full   (sql-or-empty (vector-ref r 13))
                   'endpoint_url  (sql-or-empty (vector-ref r 14))
                   'session_id    (sql-or-empty (vector-ref r 15))
                   'webhook_token (let ([w (vector-ref r 16)])
                                    (if (or (sql-null? w) (equal? w "")) "" "***"))
                   'recent_runs   (map serialize-run runs)))))
  (emit out #:pretty? pretty?))

(define (set-status id new-status pretty?)
  (call-with-app-db
   (lambda (c)
     (unless (pair? (query-rows c "SELECT 1 FROM scheduled_tasks WHERE id = ? LIMIT 1" id))
       (fail (format "no task with id ~s" id)))
     (query-exec c "UPDATE scheduled_tasks SET status = ? WHERE id = ?" new-status id)))
  (emit (hasheq 'ok #t 'id id 'status new-status) #:pretty? pretty?))

(define (cmd-runs task limit pretty?)
  (define where (if task "WHERE task_id = ? " ""))
  (define params (if task (list task) '()))
  (define sql (string-append "SELECT " run-cols " FROM task_runs " where
                             "ORDER BY started_at DESC LIMIT ?"))
  (define rows (call-with-app-db #:mode 'read-only
                 (lambda (c) (apply query-rows c sql (append params (list limit))))))
  (emit (map serialize-run rows) #:pretty? pretty?))

;; ---- arg parsing -----------------------------------------------------------
(define (opt args flag)
  (let loop ([xs args]) (cond [(null? xs) #f]
                              [(and (string=? (car xs) flag) (pair? (cdr xs))) (cadr xs)]
                              [else (loop (cdr xs))])))
(define (int-opt args flag default)
  (define v (opt args flag)) (if v (or (string->number v) default) default))

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  (define rest (filter (lambda (a) (not (string=? a "--pretty"))) args))
  (when (null? rest) (fail "missing subcommand: list|show|pause|resume|runs" #:code 2))
  (define cmd (car rest))
  (define a (cdr rest))
  (case cmd
    [("list") (cmd-list (opt a "--status") (int-opt a "--limit" 50) pretty?)]
    [("show") (when (null? a) (fail "show needs a TASK_ID" #:code 2)) (cmd-show (car a) pretty?)]
    [("pause") (when (null? a) (fail "pause needs a TASK_ID" #:code 2)) (set-status (car a) "paused" pretty?)]
    [("resume") (when (null? a) (fail "resume needs a TASK_ID" #:code 2)) (set-status (car a) "active" pretty?)]
    [("runs") (cmd-runs (opt a "--task") (int-opt a "--limit" 20) pretty?)]
    [else (fail (format "unknown subcommand: ~a" cmd) #:code 2)]))

(module+ main
  (run "odysseus-tasks" app-version dispatch))
