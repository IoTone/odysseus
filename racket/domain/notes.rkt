#lang racket/base

;; domain/notes.rkt — notes domain logic shared by the CLI and the HTTP server.
;;
;; This is the strangler-fig payoff: one serialization + list query, reused by
;; `cli/odysseus-notes.rkt` AND the `/api/notes` route in `server/main.rkt`. As
;; routes migrate off FastAPI, their logic lands here (db-kit-backed, no HTTP/CLI
;; assumptions) and both surfaces call it.

(require db
         json
         racket/string
         db-kit)

(provide notes-cols note->jsexpr list-notes        ; CLI shape (Unix tool)
         note->web-jsexpr list-notes-web)          ; HTTP shape (matches routes/note_routes.py)

;; columns selected for serialization, in fixed order
(define notes-cols
  (string-append "id,title,content,items,note_type,color,label,pinned,archived,"
                 "due_date,source,created_at,updated_at"))

;; notes.items is a JSON-array TEXT column
(define (load-items raw)
  (cond
    [(or (sql-null? raw) (not (string? raw)) (string=? raw "")) '()]
    [else (with-handlers ([exn:fail? (lambda (_) '())])
            (define v (string->jsexpr raw))
            (if (list? v) v '()))]))

(define (note->jsexpr r)
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

;; List notes (jsexpr) given an open connection. Same filters/ordering as the UI.
(define (list-notes conn
                    #:archived? [archived? #f]
                    #:label [label #f]
                    #:pinned? [pinned? #f]
                    #:limit [limit 50])
  (define where
    (string-append
     (if archived? "" "WHERE archived = 0 ")
     (if label (string-append (if archived? "WHERE " "AND ") "label = ? ") "")
     (if pinned? (string-append (if (or archived? label) "AND " "WHERE ") "pinned = 1 ") "")))
  (define params (if label (list label) '()))
  (define sql (string-append "SELECT " notes-cols " FROM notes " where
                             "ORDER BY pinned DESC, sort_order ASC, updated_at DESC LIMIT ?"))
  (map note->jsexpr (apply query-rows conn sql (append params (list limit)))))

;; ---- HTTP shape: byte-compatible with routes/note_routes.py _note_to_dict ----
;; All Note columns; NULL -> json null (not ""); items/ai_classification parsed
;; (or null); timestamps isoformat-or-null; wrapped in {"notes": [...]}.

(define (parse-json-or-null raw)
  (cond [(or (sql-null? raw) (not (string? raw)) (string=? raw "")) 'null]
        [else (with-handlers ([exn:fail? (lambda (_) 'null)]) (string->jsexpr raw))]))
(define (dt-or-null v) (if (sql-null? v) 'null (sqlite-datetime->iso v)))

(define web-cols
  (string-append "id,owner,title,content,items,note_type,color,label,pinned,archived,"
                 "due_date,source,session_id,sort_order,image_url,repeat,ai_classification,"
                 "ai_content_hash,agent_session_id,created_at,updated_at"))

(define (note->web-jsexpr r)
  (hasheq 'id                (vector-ref r 0)
          'owner             (sql-or-null (vector-ref r 1))
          'title             (sql-or-null (vector-ref r 2))
          'content           (sql-or-null (vector-ref r 3))
          'items             (parse-json-or-null (vector-ref r 4))
          'note_type         (sql-or-null (vector-ref r 5))
          'color             (sql-or-null (vector-ref r 6))
          'label             (sql-or-null (vector-ref r 7))
          'pinned            (sql->bool (vector-ref r 8))
          'archived          (sql->bool (vector-ref r 9))
          'due_date          (sql-or-null (vector-ref r 10))
          'source            (sql-or-null (vector-ref r 11))
          'session_id        (sql-or-null (vector-ref r 12))
          'sort_order        (sql->int (vector-ref r 13))
          'image_url         (sql-or-null (vector-ref r 14))
          'repeat            (let ([v (vector-ref r 15)]) (if (or (sql-null? v) (equal? v "")) "none" v))
          'ai_classification (parse-json-or-null (vector-ref r 16))
          'ai_content_hash   (sql-or-null (vector-ref r 17))
          'agent_session_id  (sql-or-null (vector-ref r 18))
          'created_at        (dt-or-null (vector-ref r 19))
          'updated_at        (dt-or-null (vector-ref r 20))))

;; Mirrors list_notes: archived? #f → active (pin/sort/updated order); #t →
;; archived (updated_at desc). Optional label filter. owner filters owner==owner
;; when supplied (= the Python route's `if user is not None`); #f = no filter
;; (auth disabled). Identity comes from upstream as a trusted header — we do NOT
;; re-implement auth here (see PORTING_PLAN "auth as a trusted header").
(define (list-notes-web conn #:archived? [archived? #f] #:label [label #f] #:owner [owner #f])
  (define clauses (append (list (string-append "archived = " (if archived? "1" "0")))
                          (if owner '("owner = ?") '())
                          (if label '("label = ?") '())))
  (define params  (append (if owner (list owner) '()) (if label (list label) '())))
  (define order (if archived? "ORDER BY updated_at DESC"
                    "ORDER BY pinned DESC, sort_order ASC, updated_at DESC"))
  (define sql (string-append "SELECT " web-cols " FROM notes WHERE "
                             (string-join clauses " AND ") " " order))
  (hasheq 'notes (map note->web-jsexpr (apply query-rows conn sql params))))
