#lang racket/base

;; odysseus-notes — notes/checklists in the `notes` table (raw SQL via db-kit).
;; Faithful Racket port of scripts/odysseus-notes.
;;
;;   odysseus-notes list [--label L] [--archived] [--pinned] [--limit N]
;;   odysseus-notes show NOTE_ID
;;   odysseus-notes search "text"
;;   odysseus-notes create --title T [--content C] [--type note|checklist]
;;                         [--color X] [--label L] [--pin]
;;   odysseus-notes delete NOTE_ID

(require db
         json
         racket/date
         racket/string
         cli-kit
         db-kit
         "../config.rkt")

;; columns selected for serialization, in fixed order
(define cols
  (string-append "id,title,content,items,note_type,color,label,pinned,archived,"
                 "due_date,source,created_at,updated_at"))

;; notes.items is a JSON-array TEXT column; mirror Python _load_items.
(define (load-items raw)
  (cond
    [(or (sql-null? raw) (not (string? raw)) (string=? raw "")) '()]
    [else (with-handlers ([exn:fail? (lambda (_) '())])
            (define v (string->jsexpr raw))
            (if (list? v) v '()))]))

(define (serialize r)
  (hasheq 'id         (vector-ref r 0)
          'title      (sql-or-empty (vector-ref r 1))
          'content    (sql-or-empty (vector-ref r 2))
          'items      (load-items (vector-ref r 3))
          'note_type  (let ([v (vector-ref r 4)]) (if (sql-null? v) "note" v))
          'color      (sql-or-empty (vector-ref r 5))
          'label      (sql-or-empty (vector-ref r 6))
          'pinned     (sql->bool (vector-ref r 7))
          'archived   (sql->bool (vector-ref r 8))
          'due_date   (sql-or-empty (vector-ref r 9))
          'source     (let ([v (vector-ref r 10)]) (if (sql-null? v) "user" v))
          'created_at (sqlite-datetime->iso (vector-ref r 11))
          'updated_at (sqlite-datetime->iso (vector-ref r 12))))

(define (now-utc-sqlite)
  (define d (seconds->date (current-seconds) #f))   ; #f = UTC
  (define (p n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))
  (format "~a-~a-~a ~a:~a:~a"
          (date-year d) (p (date-month d)) (p (date-day d))
          (p (date-hour d)) (p (date-minute d)) (p (date-second d))))

;; ---- subcommands -----------------------------------------------------------

(define (cmd-list label archived? pinned? limit pretty?)
  (define where
    (string-append
     (if archived? "" "WHERE archived = 0 ")
     (if label (string-append (if archived? "WHERE " "AND ") "label = ? ") "")
     (if pinned? (string-append (if (or archived? label) "AND " "WHERE ") "pinned = 1 ") "")))
  (define params (if label (list label) '()))
  (define sql (string-append "SELECT " cols " FROM notes " where
                             "ORDER BY pinned DESC, sort_order ASC, updated_at DESC LIMIT ?"))
  (define rows (call-with-app-db #:mode 'read-only
                 (lambda (c) (apply query-rows c sql (append params (list limit))))))
  (emit (map serialize rows) #:pretty? pretty?))

(define (cmd-show id pretty?)
  (define r (call-with-app-db #:mode 'read-only
              (lambda (c)
                (define rs (query-rows c (string-append "SELECT " cols " FROM notes WHERE id = ?") id))
                (and (pair? rs) (car rs)))))
  (unless r (fail (format "no note with id ~s" id)))
  (emit (serialize r) #:pretty? pretty?))

(define (cmd-search query limit pretty?)
  (define like (string-append "%" query "%"))
  (define rows (call-with-app-db #:mode 'read-only
                 (lambda (c)
                   (query-rows c (string-append
                                  "SELECT " cols " FROM notes "
                                  "WHERE title LIKE ? OR content LIKE ? "
                                  "ORDER BY updated_at DESC LIMIT ?")
                               like like limit))))
  (emit (map serialize rows) #:pretty? pretty?))

(define (cmd-create title content type color label pin? pretty?)
  (define id (uuid))
  (define now (now-utc-sqlite))
  (call-with-app-db
   (lambda (c)
     (query-exec c
       (string-append "INSERT INTO notes "
                      "(id,title,content,note_type,color,label,pinned,source,archived,sort_order,created_at,updated_at) "
                      "VALUES (?,?,?,?,?,?,?,?,0,0,?,?)")
       id title content type
       (if (and color (not (string=? color ""))) color sql-null)
       (if (and label (not (string=? label ""))) label sql-null)
       (if pin? 1 0) "user" now now)))
  (cmd-show id pretty?))

(define (cmd-delete id pretty?)
  (define snap
    (call-with-app-db
     (lambda (c)
       (define rs (query-rows c (string-append "SELECT " cols " FROM notes WHERE id = ?") id))
       (unless (pair? rs) (fail (format "no note with id ~s" id)))
       (define s (serialize (car rs)))
       (query-exec c "DELETE FROM notes WHERE id = ?" id)
       s)))
  (emit (hasheq 'ok #t 'deleted snap) #:pretty? pretty?))

;; crude RFC-4122-ish v4 uuid without extra deps (random enough for ids)
(define (uuid)
  (define (hx n) (apply string-append (for/list ([_ (in-range n)]) (number->string (random 16) 16))))
  (format "~a-~a-4~a-~a~a-~a" (hx 8) (hx 4) (hx 3)
          (list-ref '("8" "9" "a" "b") (random 4)) (hx 3) (hx 12)))

;; ---- arg parsing -----------------------------------------------------------
(define (opt args flag) ; value following flag, or #f
  (let loop ([xs args]) (cond [(null? xs) #f]
                              [(and (string=? (car xs) flag) (pair? (cdr xs))) (cadr xs)]
                              [else (loop (cdr xs))])))
(define (has? args flag) (and (member flag args) #t))
(define (int-opt args flag default)
  (define v (opt args flag)) (if v (or (string->number v) default) default))

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  (define rest (filter (lambda (a) (not (string=? a "--pretty"))) args))
  (when (null? rest) (fail "missing subcommand: list|show|search|create|delete" #:code 2))
  (define cmd (car rest))
  (define a (cdr rest))
  (case cmd
    [("list") (cmd-list (opt a "--label") (has? a "--archived") (has? a "--pinned")
                        (int-opt a "--limit" 50) pretty?)]
    [("show") (when (null? a) (fail "show needs a NOTE_ID" #:code 2)) (cmd-show (car a) pretty?)]
    [("search") (when (null? a) (fail "search needs a query" #:code 2))
                (cmd-search (car a) (int-opt a "--limit" 50) pretty?)]
    [("create")
     (define title (opt a "--title"))
     (unless title (fail "create needs --title" #:code 2))
     (cmd-create title (or (opt a "--content") "") (or (opt a "--type") "note")
                 (opt a "--color") (opt a "--label") (has? a "--pin") pretty?)]
    [("delete") (when (null? a) (fail "delete needs a NOTE_ID" #:code 2)) (cmd-delete (car a) pretty?)]
    [else (fail (format "unknown subcommand: ~a" cmd) #:code 2)]))

(module+ main
  (run "odysseus-notes" app-version dispatch))
