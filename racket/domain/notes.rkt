#lang racket/base

;; domain/notes.rkt — notes domain logic shared by the CLI and the HTTP server.
;;
;; This is the strangler-fig payoff: one serialization + list query, reused by
;; `cli/odysseus-notes.rkt` AND the `/api/notes` route in `server/main.rkt`. As
;; routes migrate off FastAPI, their logic lands here (db-kit-backed, no HTTP/CLI
;; assumptions) and both surfaces call it.

(require db
         json
         db-kit)

(provide notes-cols note->jsexpr list-notes)

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
