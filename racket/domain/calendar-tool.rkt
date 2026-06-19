#lang racket/base

;; domain/calendar-tool.rkt — the manage_calendar agent tool: list/create/
;; update/delete calendar events + list_calendars, with reminder Notes.
;; Port of do_manage_calendar (src/tool_implementations.py) over the local
;; SQLite calendars/calendar_events tables. Datetimes go through
;; domain/nl-datetime.rkt (the _parse_dt / parse_due_for_user port).
;;
;; Events are owner-scoped THROUGH their calendar (Python joins CalendarCal
;; and filters its owner). Reminders are Notes rows with source="calendar",
;; exactly like Python — including the duplicate-reminder dedup.

(require db
         json
         racket/string
         racket/list
         db-kit
         "util.rkt"
         "nl-datetime.rkt")

(provide manage-calendar fallback-owner
         reminder-minutes)   ; exported for tests (#4266 reminder parsing)

(define (err msg) (hasheq 'error msg 'exit_code 1))
(define (or-sql-null v) (if (eq? v #f) sql-null v))
(define (col v) (if (sql-null? v) #f v))
(define HOUR 3600)
(define DAY 86400)

(define (fallback-owner)
  (or (getenv "ODYSSEUS_FALLBACK_OWNER") "owner@localhost"))

(define action-aliases
  (hash "create" "create_event" "update" "update_event"
        "delete" "delete_event" "list" "list_events"))

;; Python `a or b or … or z`: first jtruthy operand, else the LAST operand's
;; value ('null when that key is missing/None). jtruthy gives Python falsiness
;; (None/""/0/#f/'() are false), which Racket's own `or` does not.
(define (py-or-last args . keys)
  (let loop ([ks keys])
    (define v (hash-ref args (car ks) 'null))
    (cond [(null? (cdr ks)) v]
          [(jtruthy v) v]
          [else (loop (cdr ks))])))

;; Python `(a or b or … or "") or None`: first jtruthy operand, else #f.
(define (first-truthy args . keys)
  (for/or ([k (in-list keys)]) (let ([v (hash-ref args k 'null)]) (and (jtruthy v) v))))

;; {base}::{suffix} → base; errors match Python's ValueError text
(define (resolve-base-uid uid)
  (cond
    [(not (jtruthy uid)) (error 'resolve-base-uid "empty uid")]
    [else
     (define idx (let ([m (regexp-match-positions #rx"::" uid)]) (and m (caar m))))
     (cond [(not idx) uid]
           [(zero? idx) (error 'resolve-base-uid "malformed compound UID: missing base before ::")]
           [else (substring uid 0 idx)])]))

;; first present-and-nonempty arg among names (Python's _first_nonempty_arg)
(define (first-nonempty args . names)
  (for/first ([n (in-list names)]
              #:when (let ([v (hash-ref args n #f)])
                       (and v (not (eq? v 'null)) (not (equal? v "")))))
    (hash-ref args n)))

;; reminder minutes from args (or a "remind me 10 min" description).
;; Faithful to Python's _reminder_minutes, whose `a or b or c or d or e`
;; chain skips FALSY values (None/""/0/False) and yields the last operand
;; when all are falsy — and whose `raw in (None, "", False)` membership test
;; also catches numeric 0 (0 == False in Python). Racket truthiness differs
;; (0 and "" are truthy), so this is spelled out rather than using `or`.
(define (reminder-minutes args)
  (define (g k) (hash-ref args k 'null))                ; .get(k) → 'null for None/missing
  (define raw0
    (py-or-last args 'reminder_minutes 'remind_before_minutes 'alarm_minutes 'reminder 'alarm))
  (define raw
    (if (or (eq? raw0 'null) (equal? raw0 ""))
        (let ([desc (let ([d (g 'description)]) (if (eq? d 'null) "" (format "~a" d)))])
          (if (regexp-match? #px"(?i:\\b(remind|reminder|alarm)\\b)" desc) desc raw0))
        raw0))
  (cond
    ;; raw in (None, "", False) — includes numeric 0/0.0 since 0 == False in Python
    [(or (eq? raw 'null) (equal? raw "") (eq? raw #f) (and (number? raw) (zero? raw))) #f]
    [(eq? raw #t) 10]
    [(number? raw) (max 0 (inexact->exact (truncate raw)))]
    [else
     (define text (string-downcase (string-trim (format "~a" raw))))
     (cond
       [(member text '("none" "no" "off" "false")) #f]
       ;; #4266: longest-first alternation so plural abbreviations "mins"/"hrs"
       ;; match — `mins?`/`hrs?` reach past the \b that "m|min" stranded before "s".
       [(regexp-match #px"(\\d+)\\s*(?:minutes?|mins?|m)\\b" text)
        => (lambda (m) (max 0 (string->number (cadr m))))]
       [(regexp-match #px"(\\d+)\\s*(?:hours?|hrs?|h)\\b" text)
        => (lambda (m) (max 0 (* 60 (string->number (cadr m)))))]
       [(regexp-match? #px"^[0-9]+$" text) (max 0 (string->number text))]
       [else #f])]))

;; drop a reminder-only description once the reminder is extracted from it
(define (event-description args minutes-before)
  (define desc (format "~a" (or (jget args 'description) "")))
  (cond
    [(eq? minutes-before #f) desc]
    [(regexp-match? #px"(?i:^\\s*(?:remind(?:er)?|alarm)\\s*:?\\s*\\d+\\s*(?:minutes?|mins?|m|hours?|hrs?|h)\\b.*$)"
                    desc)
     ""]
    [else desc]))

(define (ensure-default-calendar! conn owner)
  (define own (if (jtruthy owner) owner (fallback-owner)))
  (define r (query-maybe-row conn
              "SELECT id, name FROM calendars WHERE owner = ? LIMIT 1" own))
  (cond
    [r (cons (vector-ref r 0) (vector-ref r 1))]
    [else
     (define id (uuid4))
     (query-exec conn
       (string-append "INSERT INTO calendars(id, owner, name, color, source, created_at, updated_at)"
                      " VALUES(?,?,'Personal','#5b8abf','local',?,?)")
       id own (now-stamp) (now-stamp))
     (cons id "Personal")]))

(define (calendar-where owner) (if (jtruthy owner) " WHERE owner = ?" ""))
(define (owner-params owner) (if (jtruthy owner) (list owner) '()))

;; create the reminder Note → (values note-id-or-#f skip-reason-or-#f)
(define (create-calendar-reminder! conn owner summary location dtstart all-day? minutes-before is-utc?
                                   #:now-local [now-local (naive-now-local)]
                                   #:now-utc [now-utc (naive-now-utc)])
  (define remind-at0 (- dtstart (* 60 minutes-before)))
  (define now (if is-utc? now-utc now-local))
  (cond
    [(<= dtstart now) (values #f "event already passed")]
    [else
     (define remind-at (if (<= remind-at0 now) now remind-at0))
     (define start-fmt (if all-day? (fmt-day dtstart) (fmt-day-time dtstart)))
     (define text (format "~a~a — ~a" summary
                          (if (jtruthy location) (format " @ ~a" location) "") start-fmt))
     (define due-date (string-append (naive->iso remind-at) (if is-utc? "Z" "")))
     (define expected-title (format "Reminder: ~a" summary))
     (define (norm t) (regexp-replace #px"^\\s*reminder\\s*:\\s*"
                                      (string-downcase (string-trim (or t ""))) ""))
     (define existing
       (for/first ([r (in-list (apply query-rows conn
                        (string-append "SELECT id, title FROM notes WHERE archived = 0 AND due_date = ?"
                                       (if (jtruthy owner) " AND owner = ?" "") " LIMIT 25")
                        (cons due-date (owner-params owner))))]
                   #:when (equal? (norm (col (vector-ref r 1))) (norm expected-title)))
         (vector-ref r 0)))
     (cond
       [existing (values existing "duplicate reminder already exists")]
       [else
        (define id (uuid4))
        (query-exec conn
          (string-append "INSERT INTO notes(id, owner, title, items, note_type, label, due_date,"
                         " source, pinned, archived, sort_order, repeat, created_at, updated_at)"
                         " VALUES(?,?,?,?,'todo','calendar',?,'calendar',0,0,0,'none',?,?)")
          id (or-sql-null (and (jtruthy owner) owner)) expected-title
          (jsexpr->string (list (hasheq 'text text 'done #f 'checked #f)))
          due-date (now-stamp) (now-stamp))
        (values id #f)])]))

;; ---- the tool -----------------------------------------------------------------
(define (manage-calendar conn content #:owner [owner #f]
                         #:now-local [now-local (naive-now-local)]
                         #:now-utc [now-utc (naive-now-utc)])
  (define args (with-handlers ([exn:fail? (lambda (_) 'bad)])
                 (let ([v (string->jsexpr content)]) (if (hash? v) v (hasheq)))))
  (cond
    [(eq? args 'bad) (err "Invalid JSON arguments")]
    [else
     (define action0 (string-downcase
                      (string-trim (string-replace (or (jget args 'action) "list_events") "-" "_"))))
     (define action (hash-ref action-aliases action0 action0))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         [("list_calendars") (cal-list-calendars conn args owner)]
         [("list_events")    (cal-list-events conn args owner now-local now-utc)]
         [("create_event")   (cal-create-event conn args owner now-local now-utc)]
         [("update_event")   (cal-update-event conn args owner now-local)]
         [("delete_event")   (cal-delete-event conn args owner)]
         [else (err (format "Unknown action: ~a. Use list_events, create_event, update_event, delete_event, list_calendars" action))]))]))

(define (cal-list-calendars conn args owner)
  (ensure-default-calendar! conn owner)
  (define rows (apply query-rows conn
                 (string-append "SELECT name, id FROM calendars" (calendar-where owner))
                 (owner-params owner)))
  (define cals (for/list ([r (in-list rows)])
                 (hasheq 'name (col (vector-ref r 0)) 'href (vector-ref r 1))))
  (define response
    (if (pair? cals)
        (string-join
         (cons (format "Found ~a calendar(s):" (length cals))
               (for/list ([c (in-list cals)])
                 (format "- ~a (~a)" (hash-ref c 'name) (id8 (hash-ref c 'href)))))
         "\n")
        "No calendars found."))
  (hasheq 'response response 'calendars cals 'exit_code 0))

;; serialized event keys, shared by list (and the rendered lines)
(define (event-row->jsexpr r)
  ;; row: uid summary description location dtstart dtend all_day is_utc
  ;;      event_type importance calendar_id cal_name
  (define all-day? (sql->bool (vector-ref r 6)))
  (define (dt v) (let ([s (stamp->naive v)])
                   (cond [(not s) ""]
                         [all-day? (naive->date-iso s)]
                         [else (string-append (naive->iso s)
                                              (if (sql->bool (vector-ref r 7)) "Z" ""))])))
  (hasheq 'uid (vector-ref r 0) 'summary (or (col (vector-ref r 1)) "")
          'dtstart (dt (vector-ref r 4)) 'dtend (dt (vector-ref r 5))
          'all_day all-day? 'description (or (col (vector-ref r 2)) "")
          'location (or (col (vector-ref r 3)) "")
          'calendar (or (col (vector-ref r 11)) "") 'calendar_href (vector-ref r 10)
          'event_type (or (col (vector-ref r 8)) "")
          'importance (or (col (vector-ref r 9)) "normal")))

(define event-cols
  (string-append "e.uid, e.summary, e.description, e.location, e.dtstart, e.dtend,"
                 " e.all_day, e.is_utc, e.event_type, e.importance, e.calendar_id, c.name"))

(define (cal-list-events conn args owner now-local now-utc)
  (define start-raw (first-nonempty args 'start 'start_date 'range_start 'from 'dtstart 'since))
  (define end-raw (first-nonempty args 'end 'end_date 'range_end 'to 'dtend 'until))
  (define-values (start-dt end-dt parse-err)
    (with-handlers ([exn:fail? (lambda (e) (values #f #f (strip-who (exn-message e))))])
      (define s (if start-raw (parse-dt (format "~a" start-raw) #:now now-local)
                    (midnight-utc now-utc)))
      (values s (if end-raw (parse-dt (format "~a" end-raw) #:now now-local) (+ s (* 14 DAY))) #f)))
  (cond
    [parse-err (err (format "Invalid date format: ~a" parse-err))]
    [else
     (define cal-filter (jget args 'calendar))
     (define rows
       (apply query-rows conn
         (string-append "SELECT " event-cols
                        " FROM calendar_events e JOIN calendars c ON e.calendar_id = c.id"
                        " WHERE e.dtstart < ? AND e.dtend > ? AND e.status != 'cancelled'"
                        (if (jtruthy owner) " AND c.owner = ?" "")
                        (if (jtruthy cal-filter) " AND (e.calendar_id = ? OR c.name = ?)" "")
                        " ORDER BY e.dtstart")
         (append (list (naive->stamp end-dt) (naive->stamp start-dt))
                 (owner-params owner)
                 (if (jtruthy cal-filter) (list cal-filter cal-filter) '()))))
     (define events (map event-row->jsexpr rows))
     (define range-str (format "between ~a and ~a" (naive->date-iso start-dt) (naive->date-iso end-dt)))
     (define response
       (if (null? events)
           (format "No events ~a." range-str)
           (string-join
            (cons (format "Found ~a event(s) ~a:" (length events) range-str)
                  (for/list ([ev (in-list events)])
                    (define when-str
                      (if (hash-ref ev 'all_day)
                          (format "~a (all day)" (hash-ref ev 'dtstart))
                          (format "~a -> ~a" (hash-ref ev 'dtstart) (hash-ref ev 'dtend))))
                    (define line0
                      (string-append
                       (format "- ~a: [~a](#event-~a)" when-str (hash-ref ev 'summary) (hash-ref ev 'uid))
                       (if (jtruthy (hash-ref ev 'event_type)) (format " #~a" (hash-ref ev 'event_type)) "")
                       (if (and (jtruthy (hash-ref ev 'importance))
                                (not (equal? (hash-ref ev 'importance) "normal")))
                           (format " !~a" (hash-ref ev 'importance)) "")
                       (if (jtruthy (hash-ref ev 'location)) (format " @ ~a" (hash-ref ev 'location)) "")
                       (if (jtruthy (hash-ref ev 'calendar)) (format " (~a)" (hash-ref ev 'calendar)) "")))
                    (if (jtruthy (hash-ref ev 'description))
                        (let* ([d (string-replace (string-trim (hash-ref ev 'description)) "\n" " ")]
                               [d (if (> (string-length d) 120)
                                      (string-append (substring d 0 117) "...") d)])
                          (format "~a\n    ~a" line0 d))
                        line0)))
            "\n")))
     (hasheq 'response response 'events events 'exit_code 0)]))

(define (midnight-utc now-utc)
  (- now-utc (modulo now-utc DAY)))

;; calendar resolution: exact id → case-insensitive name → id prefix → default
(define (resolve-calendar conn owner href)
  (define (q sql . ps) (apply query-maybe-row conn sql ps))
  (define base (string-append "SELECT id, name FROM calendars"
                              (if (jtruthy owner) " WHERE owner = ? AND " " WHERE ")))
  (define op (owner-params owner))
  (or (apply q (string-append base "id = ? LIMIT 1") (append op (list href)))
      (apply q (string-append base "name = ? COLLATE NOCASE LIMIT 1") (append op (list href)))
      (apply q (string-append base "id LIKE ? LIMIT 1") (append op (list (string-append href "%"))))))

(define (cal-create-event conn args owner now-local now-utc)
  (define summary (jget args 'summary))
  (define dtstart-str (or (jget args 'dtstart) (jget args 'start)
                          (or (jget args 'start_time) (jget args 'when))))
  (cond
    [(or (not (jtruthy summary)) (not (jtruthy dtstart-str)))
     (err "summary and dtstart are required")]
    [else
     (define cal-href (or (jget args 'calendar_href) (jget args 'calendar)))
     (define cal
       (or (and (jtruthy cal-href)
                (let ([r (resolve-calendar conn owner (format "~a" cal-href))])
                  (and r (cons (vector-ref r 0) (vector-ref r 1)))))
           (ensure-default-calendar! conn owner)))
     (define all-day? (jtruthy (jget args 'all_day)))
     (define (parse-event-dt raw) (parse-dt-pair (parse-due-for-user (format "~a" raw) #:now now-local)
                                                 #:now now-local))
     (define-values (dtstart dtstart-utc? start-err)
       (with-handlers ([exn:fail? (lambda (e) (values #f #f (strip-who (exn-message e))))])
         (define-values (d u) (parse-event-dt dtstart-str))
         (values d u #f)))
     (cond
       [start-err (err (format "Could not parse dtstart '~a': ~a" dtstart-str start-err))]
       [else
        (define dtend-raw (or (jget args 'dtend) (jget args 'end) (jget args 'end_time)))
        (define-values (dtend is-utc? end-err)
          (cond
            [(jtruthy dtend-raw)
             (with-handlers ([exn:fail? (lambda (e) (values #f #f (strip-who (exn-message e))))])
               (define-values (d u) (parse-event-dt dtend-raw))
               (values d (or dtstart-utc? u) #f))]
            [else
             ;; duration "1h", "30m", "1hr30m" — else +1d (all-day) / +1h
             (define dur (string-downcase (string-trim (format "~a" (or (jget args 'duration) "")))))
             (define h (let ([m (regexp-match #px"([0-9]+)\\s*(?:h|hr|hours?)" dur)])
                         (if m (string->number (cadr m)) 0)))
             (define mi (let ([m (regexp-match #px"([0-9]+)\\s*(?:m|min|minutes?)" dur)])
                          (if m (string->number (cadr m)) 0)))
             (define secs (+ (* h HOUR) (* mi 60)))
             (values (+ dtstart (cond [(> secs 0) secs] [all-day? DAY] [else HOUR]))
                     dtstart-utc? #f)]))
        (cond
          [end-err (err (format "Could not parse dtend '~a': ~a" dtend-raw end-err))]
          [else
           (define minutes-before (reminder-minutes args))
           ;; dedup: same start + case-insensitive summary, not cancelled
           (define existing
             (apply query-maybe-row conn
               (string-append "SELECT e.uid, e.summary, e.location, e.dtstart, e.all_day, e.is_utc"
                              " FROM calendar_events e JOIN calendars c ON e.calendar_id = c.id"
                              " WHERE e.dtstart = ? AND e.status != 'cancelled'"
                              " AND lower(e.summary) = ?"
                              (if (jtruthy owner) " AND c.owner = ?" "") " LIMIT 1")
               (append (list (naive->stamp dtstart) (string-downcase summary))
                       (owner-params owner))))
           (cond
             [existing
              (define-values (note-id skip-reason)
                (if minutes-before
                    (create-calendar-reminder! conn owner
                      (let ([s (col (vector-ref existing 1))]) (if (jtruthy s) s summary))
                      (or (col (vector-ref existing 2)) "")
                      (stamp->naive (vector-ref existing 3))
                      (sql->bool (vector-ref existing 4)) minutes-before
                      (sql->bool (vector-ref existing 5))
                      #:now-local now-local #:now-utc now-utc)
                    (values #f #f)))
              (define reminder-text
                (if minutes-before
                    (if note-id
                        (format "; reminder set ~a min before" minutes-before)
                        (format "; reminder not set (~a)" (or skip-reason "reminder time already passed")))
                    ""))
              (hasheq 'response (format "Event already exists: '~a' on ~a~a" summary dtstart-str reminder-text)
                      'uid (vector-ref existing 0)
                      'reminder_note_id (or note-id 'null)
                      'reminder_skipped_reason (or skip-reason 'null)
                      'duplicate #t 'exit_code 0)]
             [else
              (define event-type (first-truthy args 'event_type 'tag 'category 'type))
              (define importance (or (jget args 'importance) "normal"))
              (define uid (uuid4))
              (query-exec conn
                (string-append "INSERT INTO calendar_events(uid, calendar_id, summary, description,"
                               " location, dtstart, dtend, all_day, is_utc, rrule, status, importance,"
                               " event_type, created_at, updated_at)"
                               " VALUES(?,?,?,?,?,?,?,?,?,?,'confirmed',?,?,?,?)")
                uid (car cal) summary (event-description args minutes-before)
                (or (jget args 'location) "")
                (naive->stamp dtstart) (naive->stamp dtend)
                (if all-day? 1 0) (if (and is-utc? (not all-day?)) 1 0)
                (or (jget args 'rrule) "") importance (or-sql-null event-type)
                (now-stamp) (now-stamp))
              (define-values (note-id skip-reason)
                (if minutes-before
                    (create-calendar-reminder! conn owner summary (or (jget args 'location) "")
                                               dtstart all-day? minutes-before
                                               (and is-utc? (not all-day?))
                                               #:now-local now-local #:now-utc now-utc)
                    (values #f #f)))
              (define tag-blurb (if event-type (format " [~a]" event-type) ""))
              (define reminder-blurb
                (cond [(not minutes-before) ""]
                      [note-id (format " with reminder ~a min before" minutes-before)]
                      [else (format " without reminder (~a)" (or skip-reason "reminder time already passed"))]))
              (hasheq 'response (format "Created event [~a](#event-~a)~a on ~a~a"
                                        summary uid tag-blurb dtstart-str reminder-blurb)
                      'uid uid 'anchor (format "[~a](#event-~a)" summary uid)
                      'reminder_note_id (or note-id 'null)
                      'reminder_skipped_reason (or skip-reason 'null)
                      'exit_code 0)])])])]))

(define (find-event conn owner base-uid)
  (apply query-maybe-row conn
    (string-append "SELECT e.uid, e.all_day FROM calendar_events e"
                   " JOIN calendars c ON e.calendar_id = c.id WHERE e.uid = ?"
                   (if (jtruthy owner) " AND c.owner = ?" "") " LIMIT 1")
    (cons base-uid (owner-params owner))))

(define (cal-update-event conn args owner now-local)
  (define uid (jget args 'uid))
  (cond
    [(not (jtruthy uid)) (err "uid is required")]
    [else
     (define base-uid (with-handlers ([exn:fail? (lambda (e) e)]) (resolve-base-uid uid)))
     (cond
       [(exn:fail? base-uid) (err (strip-who (exn-message base-uid)))]
       [else
        (define ev (find-event conn owner base-uid))
        (cond
          [(not ev) (err (format "Event ~a not found" uid))]
          [else
           (define (parse-event-dt raw)
             (parse-dt-pair (parse-due-for-user (format "~a" raw) #:now now-local) #:now now-local))
           ;; Python's `args.get(k) is not None` — a present JSON false counts
           (define (given? k) (and (hash-has-key? args k) (not (eq? (hash-ref args k) 'null))))
           (define sets '())   ; built up as (column value) pairs, mutably below
           (define (add! col v) (set! sets (cons (list col v) sets)))
           (for ([k (in-list '(summary description location))])
             (when (given? k) (add! (symbol->string k) (hash-ref args k))))
           (define eff-all-day
             (if (given? 'all_day)
                 (jtruthy (hash-ref args 'all_day))
                 (sql->bool (vector-ref ev 1))))
           (when (given? 'dtstart)
             (define-values (d u) (parse-event-dt (hash-ref args 'dtstart)))
             (add! "dtstart" (naive->stamp d))
             (add! "is_utc" (if (and u (not eff-all-day)) 1 0)))
           (when (given? 'dtend)
             (define-values (d _u) (parse-event-dt (hash-ref args 'dtend)))
             (add! "dtend" (naive->stamp d)))
           (when (given? 'all_day)
             (add! "all_day" (if (jtruthy (hash-ref args 'all_day)) 1 0)))
           ;; Python: _tag = (event_type or tag or category or type); if _tag is
           ;; not None: ev.event_type = _tag or None. First jtruthy → set it;
           ;; else fall to `type`'s value — present (even "") clears to NULL,
           ;; missing/None skips entirely.
           (let ([tag (py-or-last args 'event_type 'tag 'category 'type)])
             (unless (eq? tag 'null)
               (add! "event_type" (if (jtruthy tag) tag sql-null))))
           (when (given? 'importance) (add! "importance" (hash-ref args 'importance)))
           ;; (Python's update_event never applies rrule, despite the schema
           ;;  advertising it — kept bug-compatible.)
           (add! "updated_at" (now-stamp))
           (apply query-exec conn
                  (string-append "UPDATE calendar_events SET "
                                 (string-join (for/list ([s (in-list (reverse sets))])
                                                (string-append (car s) " = ?")) ", ")
                                 " WHERE uid = ?")
                  (append (map cadr (reverse sets)) (list base-uid)))
           (hasheq 'response (format "Updated event ~a" uid) 'exit_code 0)])])]))

(define (cal-delete-event conn args owner)
  (define uid (jget args 'uid))
  (cond
    [(not (jtruthy uid)) (err "uid is required")]
    [else
     (define base-uid (with-handlers ([exn:fail? (lambda (e) e)]) (resolve-base-uid uid)))
     (cond
       [(exn:fail? base-uid) (err (strip-who (exn-message base-uid)))]
       [else
        (define ev (find-event conn owner base-uid))
        (cond
          [(not ev) (err (format "Event ~a not found" uid))]
          [else
           (query-exec conn "DELETE FROM calendar_events WHERE uid = ?" base-uid)
           (hasheq 'response (format "Deleted event ~a" uid) 'exit_code 0)])])]))

;; racket error messages carry a "who: " prefix; Python's ValueError text doesn't
(define (strip-who msg)
  (define m (regexp-match #px"^[^\\s:]+: (.*)$" msg))
  (if m (cadr m) msg))
