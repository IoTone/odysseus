#lang racket/base

;; domain/sessions.rkt — chat-session domain logic shared by the CLI and the
;; HTTP server (same pattern as domain/notes.rkt). Powers both
;; `cli/odysseus-sessions.rkt` and `GET /api/sessions`.

(require db
         db-kit)

(provide sessions-cols session->jsexpr list-sessions)

(define sessions-cols
  (string-append "id,name,model,endpoint_url,owner,folder,archived,rag,is_important,"
                 "message_count,total_input_tokens,total_output_tokens,last_accessed,created_at"))

(define (session->jsexpr r)
  (hasheq 'id                  (vector-ref r 0)
          'name                (vector-ref r 1)
          'model               (vector-ref r 2)
          'endpoint_url        (vector-ref r 3)
          'owner               (sql-or-empty (vector-ref r 4))
          'folder              (sql-or-empty (vector-ref r 5))
          'archived            (sql->bool (vector-ref r 6))
          'rag                 (sql->bool (vector-ref r 7))
          'is_important        (sql->bool (vector-ref r 8))
          'message_count       (sql->int (vector-ref r 9))
          'total_input_tokens  (sql->int (vector-ref r 10))
          'total_output_tokens (sql->int (vector-ref r 11))
          'last_accessed       (sqlite-datetime->iso (vector-ref r 12))
          'created_at          (sqlite-datetime->iso (vector-ref r 13))))

;; archived-mode: #f = exclude archived (default) · 'all = include · 'only = only archived
(define (list-sessions conn #:archived-mode [archived-mode #f] #:folder [folder #f] #:limit [limit 50])
  (define where
    (string-append
     (cond [(eq? archived-mode #f) "WHERE archived = 0 "]
           [(eq? archived-mode 'only) "WHERE archived = 1 "]
           [else ""])
     (if folder (string-append (if (eq? archived-mode 'all) "WHERE " "AND ") "folder = ? ") "")))
  (define params (if folder (list folder) '()))
  (define sql (string-append "SELECT " sessions-cols " FROM sessions " where
                             "ORDER BY last_accessed DESC LIMIT ?"))
  (map session->jsexpr (apply query-rows conn sql (append params (list limit)))))
