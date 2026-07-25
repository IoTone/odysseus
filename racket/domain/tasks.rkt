#lang racket/base

;; domain/tasks.rkt — the manage_tasks agent tool: CRUD on scheduled tasks.
;; Port of src/tool_implementations.py do_manage_tasks plus the slice of
;; src/task_scheduler.py compute_next_run it actually calls — the legacy
;; naive-UTC path (schedule, scheduled_time, scheduled_day); the tz/cron/once
;; variants take parameters this call site never passes.
;;
;; The `run` action needs the live task scheduler; without one Python returns
;; {"error": "Task scheduler not available"} — which is exactly this CLI's
;; situation, so that branch is the faithful port, not a stub.

(require db
         json
         racket/string
         racket/date          ; find-seconds
         db-kit
         "util.rkt")

(provide compute-next-run manage-tasks)

;; ---- compute_next_run (legacy naive-UTC path) -------------------------------
;; → "YYYY-MM-DD HH:MM:SS.000000" (the SQLAlchemy DateTime text shape) or #f.
;; #:now is injectable (seconds, UTC) so tests are deterministic.

(define DAY 86400)

(define (days-in-month y m)
  (define feb (if (and (zero? (modulo y 4)) (or (not (zero? (modulo y 100))) (zero? (modulo y 400)))) 29 28))
  (vector-ref (vector 31 feb 31 30 31 30 31 31 30 31 30 31) (sub1 m)))

(define (utc-seconds y m d hh mm) (find-seconds 0 mm hh d m y #f))

(define (seconds->stamp s)
  (define d (seconds->date s #f))
  (define (p2 n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~a ~a:~a:~a.000000" (date-year d) (p2 (date-month d)) (p2 (date-day d))
          (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d))))

;; strict HH:MM — fail closed (→ #f) on malformed input, like the Python
(define (parse-hhmm s)
  (define parts (string-split (if (string? s) s "") ":" #:trim? #f))
  (and (>= (length parts) 2)
       (let ([h (string->number (string-trim (car parts)))]
             [m (string->number (string-trim (cadr parts)))])
         (and (exact-integer? h) (exact-integer? m) (<= 0 h 23) (<= 0 m 59) (list h m)))))

(define (compute-next-run schedule scheduled-time [scheduled-day #f]
                          #:now [now (current-seconds)])
  (define hm (and (jtruthy scheduled-time) (parse-hhmm scheduled-time)))
  (cond
    [(not (member schedule '("daily" "weekly" "monthly"))) #f]  ; once/cron/unknown → none
    [(not hm) #f]
    [else
     (define h (car hm)) (define m (cadr hm))
     (define nd (seconds->date now #f))
     (define today-candidate (utc-seconds (date-year nd) (date-month nd) (date-day nd) h m))
     (define result
       (case schedule
         [("daily") (if (<= today-candidate now) (+ today-candidate DAY) today-candidate)]
         [("weekly")
          (define day (if (exact-integer? scheduled-day) scheduled-day 0))   ; 0=Monday
          (define pywd (modulo (+ (date-week-day nd) 6) 7))                  ; Racket 0=Sunday
          (define ahead0 (- day pywd))
          (define ahead (if (or (< ahead0 0) (and (= ahead0 0) (<= today-candidate now)))
                            (+ ahead0 7) ahead0))
          (+ today-candidate (* ahead DAY))]
         [("monthly")
          (define day (if (exact-integer? scheduled-day) scheduled-day 1))
          (define (clamped y mo)                ; out-of-range day → last day of month
            (define dim (days-in-month y mo))
            (utc-seconds y mo (if (<= 1 day dim) day dim) h m))
          (define candidate (clamped (date-year nd) (date-month nd)))
          (if (<= candidate now)
              (let-values ([(y2 m2) (if (= (date-month nd) 12)
                                        (values (add1 (date-year nd)) 1)
                                        (values (date-year nd) (add1 (date-month nd))))])
                (clamped y2 m2))
              candidate)]))
     (seconds->stamp result)]))

;; ---- do_manage_tasks ---------------------------------------------------------

(define (err msg) (hasheq 'error msg 'exit_code 1))
(define (or-sql-null v) (if (eq? v #f) sql-null v))
(define (col v) (let ([x v]) (if (sql-null? x) #f x)))    ; sql-null -> #f

;; next_run/last_run serialization: isoformat + "Z" (json null when NULL)
(define (dt-z v) (if (sql-null? v) 'null (string-append (sqlite-datetime->iso v) "Z")))

;; exact-id lookup with the Python guard semantics:
;; #f = not found; 'forbidden = someone else's (→ "Access denied")
(define (find-task conn task-id owner)
  (define r (query-maybe-row conn
              (string-append "SELECT id, owner, name, trigger_type, schedule,"
                             " scheduled_time, scheduled_day FROM scheduled_tasks WHERE id = ?")
              task-id))
  (cond [(not r) #f]
        ;; Fail CLOSED on owner-less rows (#5264): if the caller is scoped to an
        ;; owner, any task whose owner != caller — INCLUDING a NULL/owner-less
        ;; row — is forbidden. The old middle term `(jtruthy (col …))` let a
        ;; caller edit/run another tenant's owner-less scheduled task.
        [(and (jtruthy owner) (not (equal? (vector-ref r 1) owner)))
         'forbidden]
        [else r]))

;; weekday name → 0=Monday..6=Sunday (matches compute-next-run's convention)
(define day-index
  (hash "monday" 0 "mon" 0 "tuesday" 1 "tue" 1 "tues" 1 "wednesday" 2 "wed" 2
        "thursday" 3 "thu" 3 "thur" 3 "thurs" 3 "friday" 4 "fri" 4
        "saturday" 5 "sat" 5 "sunday" 6 "sun" 6))

;; Natural-language arg coercion (Python's do_manage_tasks preamble): let the
;; model say {"task": "...", "time": "8am", "day_of_week": "friday"} and infer
;; action=create + the canonical field names.
(define (coerce-task-args args)
  (define (has? k)     (jtruthy (jget args k)))                        ; Python truthiness
  (define (present? a k) (and (hash-has-key? a k) (not (eq? (hash-ref a k) 'null)))) ; is not None
  (let* ([a args]
         [a (if (and (not (jtruthy (jget a 'action)))
                     (ormap (lambda (k) (present? a k)) '(task description schedule time day_of_week)))
                (hash-set a 'action "create") a)]
         [a (if (and (has? 'task) (not (jtruthy (jget a 'name))))   (hash-set a 'name (jget a 'task)) a)]
         [a (if (and (has? 'task) (not (jtruthy (jget a 'prompt)))) (hash-set a 'prompt (jget a 'task)) a)]
         [a (if (and (has? 'description) (not (jtruthy (jget a 'prompt)))) (hash-set a 'prompt (jget a 'description)) a)]
         [a (if (and (has? 'time) (not (jtruthy (jget a 'scheduled_time)))) (hash-set a 'scheduled_time (jget a 'time)) a)]
         [a (if (and (present? a 'day_of_week) (not (present? a 'scheduled_day)))
                (let ([d (hash-ref day-index (string-downcase (string-trim (format "~a" (jget a 'day_of_week)))) #f)])
                  (if d (hash-set a 'scheduled_day d) a))
                a)])
    a))

;; manage-tasks : conn × JSON-args-string × #:owner → result jsexpr
(define (manage-tasks conn content #:owner [owner #f])
  (define args0 (with-handlers ([exn:fail? (lambda (_) 'bad)])
                  (let ([v (string->jsexpr content)]) (if (hash? v) v (hasheq)))))
  (cond
    [(eq? args0 'bad) (err "Invalid JSON arguments")]
    [else
     (define args (coerce-task-args args0))
     (define action (or (jget args 'action) "list"))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         [("list")   (tasks-list conn args owner)]
         [("create") (tasks-create conn args owner)]
         [("edit")   (tasks-edit conn args owner)]
         [("delete") (tasks-delete conn args owner)]
         [("pause" "resume") (tasks-pause/resume conn args owner action)]
         [("run")    (tasks-run conn args owner)]
         [else (err (format "Unknown action: ~a" action))]))]))

(define (tasks-list conn args owner)
  (define rows (apply query-rows conn
                 (string-append "SELECT id, name, status, schedule, scheduled_time, next_run"
                                " FROM scheduled_tasks"
                                (if (jtruthy owner) " WHERE owner = ?" "")
                                " ORDER BY created_at DESC")
                 (if (jtruthy owner) (list owner) '())))
  (cond
    [(null? rows) (hasheq 'response "No scheduled tasks found." 'exit_code 0)]
    [else
     ;; numbered "N. name (id) — status[, schedule][, time][, next <iso>Z]"
     (define lines
       (cons (format "Found ~a tasks:" (length rows))
             (for/list ([r (in-list rows)] [idx (in-naturals 1)])
               (define bits
                 (append (list (or (col (vector-ref r 2)) "unknown"))
                         (if (jtruthy (col (vector-ref r 3))) (list (format "~a" (col (vector-ref r 3)))) '())
                         (if (jtruthy (col (vector-ref r 4))) (list (format "~a" (col (vector-ref r 4)))) '())
                         (if (sql-null? (vector-ref r 5)) '()
                             (list (format "next ~aZ" (sqlite-datetime->iso (vector-ref r 5)))))))
               (format "~a. ~a (~a) — ~a" idx (col (vector-ref r 1)) (vector-ref r 0)
                       (string-join bits ", ")))))
     (hasheq 'response (string-join lines "\n") 'exit_code 0)]))

(define (tasks-create conn args owner)
  (define task-type (or (jget args 'task_type) "llm"))
  (define trigger-type (or (jget args 'trigger_type) "schedule"))
  (cond
    [(and (member task-type '("llm" "research")) (not (jtruthy (jget args 'prompt))))
     (err "Prompt is required for llm/research tasks")]
    [(and (equal? task-type "action") (not (jtruthy (jget args 'action_name))))
     (err "action_name is required for action tasks")]
    [else
     (define schedule? (equal? trigger-type "schedule"))
     (define next-run
       (and schedule?
            (compute-next-run (or (jget args 'schedule) "daily")
                              (or (jget args 'scheduled_time) "09:00")
                              (jget args 'scheduled_day))))
     (define task-id (uuid4))
     (define name
       (let ([n (jget args 'name)])
         (if (jtruthy n) n
             (let ([base (or (jget args 'prompt) (jget args 'action_name) "Task")])
               (substring base 0 (min 50 (string-length base)))))))
     (define now (now-stamp))
     (query-exec conn
       (string-append "INSERT INTO scheduled_tasks(id, owner, name, prompt, task_type, action,"
                      " schedule, scheduled_time, scheduled_day, trigger_type, trigger_event,"
                      " trigger_count, trigger_counter, next_run, status, output_target,"
                      " run_count, created_at, updated_at)"
                      " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,?,'active',?,0,?,?)")
       task-id (or-sql-null owner) name (or-sql-null (jget args 'prompt)) task-type
       (or-sql-null (jget args 'action_name))
       (or-sql-null (and schedule? (jget args 'schedule)))
       (or-sql-null (and schedule? (or (jget args 'scheduled_time) "09:00")))
       (or-sql-null (jget args 'scheduled_day))
       trigger-type (or-sql-null (jget args 'trigger_event)) (or-sql-null (jget args 'trigger_count))
       (or-sql-null next-run) (or (jget args 'output_target) "session")
       now now)
     (hasheq 'response (format "Created task '~a' (id: ~a)" name task-id)
             'task_id task-id 'exit_code 0)]))

;; the (column . changed-label) pairs the edit action accepts, in Python's order
(define edit-fields
  '((name . "name") (prompt . "prompt") (output_target . "output_target")
    (task_type . "task_type") (action_name . "action") (trigger_type . "trigger_type")
    (trigger_event . "trigger_event") (trigger_count . "trigger_count")))
(define (edit-column k) (if (eq? k 'action_name) "action" (symbol->string k)))

(define (tasks-edit conn args owner)
  (define task-id (jget args 'task_id))
  (define n (and (jtruthy task-id) (find-task conn task-id owner)))
  (cond
    [(not (jtruthy task-id)) (err "task_id is required for edit")]
    [(not n) (err (format "Task ~a not found" task-id))]
    [(eq? n 'forbidden) (err "Access denied")]
    [else
     (define sets (for/list ([f (in-list edit-fields)] #:when (jget args (car f)))
                    (list (edit-column (car f)) (jget args (car f)) (cdr f))))
     (define sched-sets (for/list ([f (in-list '(schedule scheduled_time scheduled_day))]
                                   #:when (jget args f))
                          (list (symbol->string f) (jget args f) (symbol->string f))))
     (define changed (append (map caddr sets) (map caddr sched-sets)))
     ;; post-update values decide the next_run recompute (Python mutates then reads)
     (define (post col-name idx)
       (cond [(assoc col-name (map (lambda (s) (cons (car s) (cadr s))) (append sets sched-sets))) => cdr]
             [else (col (vector-ref n idx))]))
     (define recompute?
       (and (pair? sched-sets) (equal? (or (post "trigger_type" 3) "schedule") "schedule")))
     (define next-run-sets
       (if recompute?
           (list (list "next_run"
                       (or-sql-null (compute-next-run (post "schedule" 4) (post "scheduled_time" 5)
                                                      (post "scheduled_day" 6)))
                       #f))
           '()))
     (define all-sets (append sets sched-sets next-run-sets
                              (list (list "updated_at" (now-stamp) #f))))
     (apply query-exec conn
            (string-append "UPDATE scheduled_tasks SET "
                           (string-join (for/list ([s (in-list all-sets)])
                                          (string-append (car s) " = ?")) ", ")
                           " WHERE id = ?")
            (append (map cadr all-sets) (list (vector-ref n 0))))
     (define final-name (or (jget args 'name) (col (vector-ref n 2))))
     (hasheq 'response (format "Updated task '~a': ~a" final-name (string-join changed ", "))
             'exit_code 0)]))

(define (tasks-delete conn args owner)
  (define task-id (jget args 'task_id))
  (define n (and (jtruthy task-id) (find-task conn task-id owner)))
  (cond
    [(not (jtruthy task-id)) (err "task_id is required for delete")]
    [(not n) (err (format "Task ~a not found" task-id))]
    [(eq? n 'forbidden) (err "Access denied")]
    [else
     (query-exec conn "DELETE FROM scheduled_tasks WHERE id = ?" (vector-ref n 0))
     (hasheq 'response (format "Deleted task '~a'" (col (vector-ref n 2))) 'exit_code 0)]))

(define (tasks-pause/resume conn args owner action)
  (define task-id (jget args 'task_id))
  (define n (and (jtruthy task-id) (find-task conn task-id owner)))
  (cond
    [(not (jtruthy task-id)) (err (format "task_id is required for ~a" action))]
    [(not n) (err (format "Task ~a not found" task-id))]
    [(eq? n 'forbidden) (err "Access denied")]
    [else
     (cond
       [(equal? action "pause")
        (query-exec conn "UPDATE scheduled_tasks SET status = 'paused', updated_at = ? WHERE id = ?"
                    (now-stamp) (vector-ref n 0))]
       [(equal? (or (col (vector-ref n 3)) "schedule") "schedule")   ; resume, schedule trigger
        (query-exec conn
          "UPDATE scheduled_tasks SET status = 'active', next_run = ?, updated_at = ? WHERE id = ?"
          (or-sql-null (compute-next-run (col (vector-ref n 4)) (col (vector-ref n 5))
                                         (col (vector-ref n 6))))
          (now-stamp) (vector-ref n 0))]
       [else                                                          ; resume, event trigger
        (query-exec conn "UPDATE scheduled_tasks SET status = 'active', updated_at = ? WHERE id = ?"
                    (now-stamp) (vector-ref n 0))])
     (hasheq 'response (format "Task '~a' ~ad" (col (vector-ref n 2)) action) 'exit_code 0)]))

(define (tasks-run conn args owner)
  (define task-id (jget args 'task_id))
  (define n (and (jtruthy task-id) (find-task conn task-id owner)))
  (cond
    [(not (jtruthy task-id)) (err "task_id is required for run")]
    [(not n) (err (format "Task ~a not found" task-id))]
    [(eq? n 'forbidden) (err "Access denied")]
    [else (err "Task scheduler not available")]))   ; no live scheduler in this CLI
