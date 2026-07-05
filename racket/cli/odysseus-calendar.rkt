#lang racket/base

;; odysseus-calendar — calendar events in `calendar_events` + `calendars`
;; (raw SQL via db-kit). Faithful Racket port of scripts/odysseus-calendar.
;;
;;   odysseus-calendar list [--start D] [--end D] [--calendar NAME] [--limit N]
;;   odysseus-calendar show UID
;;   odysseus-calendar calendars
;;   odysseus-calendar create --title T --start D [--end D] [--calendar NAME] ...
;;   odysseus-calendar delete UID
;;
;; Dates: YYYY-MM-DD (→ local midnight) or ISO YYYY-MM-DDTHH:MM[:SS]. Timezone
;; offsets/Z are treated as naive-local (matches the dominant on-disk corpus).

(require db
         racket/date
         racket/string
         cli-kit
         db-kit
         "../config.rkt")

;; ---- date helpers ----------------------------------------------------------
(define (parse-dt->secs s)
  (define m (regexp-match #px"^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[T ]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?)?" s))
  (unless m (fail (format "invalid date ~s (use YYYY-MM-DD or ISO)" s)))
  (define (n i) (let ([x (list-ref m i)]) (if x (string->number x) 0)))
  (find-seconds (n 6) (n 5) (n 4) (n 3) (n 2) (n 1) #t))

(define (p2 n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))
(define (secs->sqlite secs)
  (define d (seconds->date secs #t))
  (format "~a-~a-~a ~a:~a:~a.000000"
          (date-year d) (p2 (date-month d)) (p2 (date-day d))
          (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d))))

;; ---- serialization ---------------------------------------------------------
(define event-cols
  (string-append "e.uid,e.calendar_id,c.name,e.summary,e.description,e.location,e.dtstart,e.dtend,"
                 "e.all_day,e.is_utc,e.rrule,e.color,e.status,e.importance,e.event_type"))
(define event-from "FROM calendar_events e LEFT JOIN calendars c ON c.id = e.calendar_id")

(define (dt-iso v is-utc?)
  (define iso (sqlite-datetime->iso v))
  (if (and (not (string=? iso "")) is-utc?) (string-append iso "Z") iso))

(define (serialize-event r)
  (define is-utc? (sql->bool (vector-ref r 9)))
  (hasheq 'uid           (vector-ref r 0)
          'calendar_id   (vector-ref r 1)
          'calendar_name (sql-or-empty (vector-ref r 2))
          'summary       (vector-ref r 3)
          'description   (sql-or-empty (vector-ref r 4))
          'location      (sql-or-empty (vector-ref r 5))
          'dtstart       (dt-iso (vector-ref r 6) is-utc?)
          'dtend         (dt-iso (vector-ref r 7) is-utc?)
          'all_day       (sql->bool (vector-ref r 8))
          'is_utc        is-utc?
          'rrule         (sql-or-empty (vector-ref r 10))
          'color         (sql-or-empty (vector-ref r 11))
          'status        (sql-or-empty (vector-ref r 12))
          'importance    (sql-or-empty (vector-ref r 13))
          'event_type    (sql-or-empty (vector-ref r 14))))

(define (fetch-event id)
  (call-with-app-db #:mode 'read-only
    (lambda (c)
      (define rs (query-rows c (string-append "SELECT " event-cols " " event-from " WHERE e.uid = ?") id))
      (and (pair? rs) (car rs)))))

(define (calendar-id-by-name c name)
  (define rs (query-rows c "SELECT id FROM calendars WHERE name = ? LIMIT 1" name))
  (and (pair? rs) (vector-ref (car rs) 0)))

;; ---- subcommands -----------------------------------------------------------

(define (cmd-list start end calname limit pretty?)
  (define start-secs (if start (parse-dt->secs start) (current-seconds)))
  (define end-secs (if end (parse-dt->secs end) (+ start-secs (* 30 86400))))
  (emit
   (call-with-app-db #:mode 'read-only
     (lambda (c)
       (define cal-filter
         (cond [calname (define id (calendar-id-by-name c calname))
                        (unless id (fail (format "no calendar named ~s" calname)))
                        id]
               [else #f]))
       ;; #2065: OVERLAP semantics (dtstart < end AND dtend > start), matching
       ;; the web route + recurring-expansion contract — keeps multi-day /
       ;; in-progress events that began before `start` but are still running in
       ;; the window. (Was dtstart >= start AND dtstart < end, which dropped
       ;; them.) Placeholders stay start-then-end: dtend > start, dtstart < end.
       (define sql (string-append "SELECT " event-cols " " event-from
                                  " WHERE e.dtend > ? AND e.dtstart < ?"
                                  (if cal-filter " AND e.calendar_id = ?" "")
                                  " ORDER BY e.dtstart ASC LIMIT ?"))
       (define params (append (list (secs->sqlite start-secs) (secs->sqlite end-secs))
                              (if cal-filter (list cal-filter) '())
                              (list limit)))
       (map serialize-event (apply query-rows c sql params))))
   #:pretty? pretty?))

(define (cmd-show uid pretty?)
  (define r (fetch-event uid))
  (unless r (fail (format "no event with uid ~s" uid)))
  (emit (serialize-event r) #:pretty? pretty?))

(define (cmd-calendars pretty?)
  (emit
   (call-with-app-db #:mode 'read-only
     (lambda (c)
       (for/list ([r (in-list (query-rows c (string-append
              "SELECT id,name,color,source,"
              "(SELECT COUNT(*) FROM calendar_events WHERE calendar_id = calendars.id) "
              "FROM calendars ORDER BY name ASC")))])
         (hasheq 'id          (vector-ref r 0)
                 'name        (vector-ref r 1)
                 'color       (sql-or-empty (vector-ref r 2))
                 'source      (let ([s (vector-ref r 3)]) (if (sql-null? s) "local" s))
                 'event_count (sql->int (vector-ref r 4))))))
   #:pretty? pretty?))

(define (cmd-create title start end calname description location all-day? importance event-type pretty?)
  (define dtstart-secs (parse-dt->secs start))
  (define dtend-secs (if end (parse-dt->secs end) (+ dtstart-secs 3600)))
  (define uid (gen-uuid))
  (define now (secs->sqlite (current-seconds)))
  (call-with-app-db
   (lambda (c)
     (define cal-id
       (cond [calname (or (calendar-id-by-name c calname) (fail (format "no calendar named ~s" calname)))]
             [else (define rs (query-rows c "SELECT id FROM calendars ORDER BY created_at ASC LIMIT 1"))
                   (if (pair? rs) (vector-ref (car rs) 0)
                       (fail "no calendars exist; create one in the web UI first"))]))
     (query-exec c
       (string-append "INSERT INTO calendar_events "
                      "(uid,calendar_id,summary,description,location,dtstart,dtend,all_day,is_utc,"
                      "importance,event_type,status,created_at,updated_at) "
                      "VALUES (?,?,?,?,?,?,?,?,0,?,?,'confirmed',?,?)")
       uid cal-id title description location
       (secs->sqlite dtstart-secs) (secs->sqlite dtend-secs)
       (if all-day? 1 0) importance
       (if (and event-type (not (string=? event-type ""))) event-type sql-null)
       now now)))
  (cmd-show uid pretty?))

(define (cmd-delete uid pretty?)
  (define snap
    (call-with-app-db
     (lambda (c)
       (define rs (query-rows c (string-append "SELECT " event-cols " " event-from " WHERE e.uid = ?") uid))
       (unless (pair? rs) (fail (format "no event with uid ~s" uid)))
       (define s (serialize-event (car rs)))
       (query-exec c "DELETE FROM calendar_events WHERE uid = ?" uid)
       s)))
  (emit (hasheq 'ok #t 'deleted snap) #:pretty? pretty?))

(define (gen-uuid)
  (define (hx n) (apply string-append (for/list ([_ (in-range n)]) (number->string (random 16) 16))))
  (format "~a-~a-4~a-~a~a-~a" (hx 8) (hx 4) (hx 3)
          (list-ref '("8" "9" "a" "b") (random 4)) (hx 3) (hx 12)))

;; ---- arg parsing -----------------------------------------------------------
(define (opt args flag)
  (let loop ([xs args]) (cond [(null? xs) #f]
                              [(and (string=? (car xs) flag) (pair? (cdr xs))) (cadr xs)]
                              [else (loop (cdr xs))])))
(define (has? args flag) (and (member flag args) #t))
(define (int-opt args flag d) (define v (opt args flag)) (if v (or (string->number v) d) d))

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  (define rest (filter (lambda (a) (not (string=? a "--pretty"))) args))
  (when (null? rest) (fail "missing subcommand: list|show|calendars|create|delete" #:code 2))
  (define cmd (car rest)) (define a (cdr rest))
  (case cmd
    [("list") (cmd-list (opt a "--start") (opt a "--end") (opt a "--calendar") (int-opt a "--limit" 100) pretty?)]
    [("show") (when (null? a) (fail "show needs a UID" #:code 2)) (cmd-show (car a) pretty?)]
    [("calendars") (cmd-calendars pretty?)]
    [("create")
     (define title (opt a "--title")) (unless title (fail "create needs --title" #:code 2))
     (define start (opt a "--start")) (unless start (fail "create needs --start" #:code 2))
     (cmd-create title start (opt a "--end") (opt a "--calendar")
                 (or (opt a "--description") "") (or (opt a "--location") "")
                 (has? a "--all-day") (or (opt a "--importance") "normal")
                 (opt a "--event-type") pretty?)]
    [("delete") (when (null? a) (fail "delete needs a UID" #:code 2)) (cmd-delete (car a) pretty?)]
    [else (fail (format "unknown subcommand: ~a" cmd) #:code 2)]))

(module+ main
  (run "odysseus-calendar" app-version dispatch))
