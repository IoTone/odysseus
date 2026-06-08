#lang racket/base

;; odysseus-sessions — chat sessions in the `sessions` table (raw SQL via db-kit).
;; Faithful Racket port of scripts/odysseus-sessions.
;;
;;   odysseus-sessions list [--archived [only]] [--folder F] [--limit N]
;;   odysseus-sessions show SESSION_ID
;;   odysseus-sessions archive|unarchive SESSION_ID
;;   odysseus-sessions delete SESSION_ID --yes      (irreversible)

(require db
         racket/string
         cli-kit
         db-kit
         "../config.rkt")

(define cols
  (string-append "id,name,model,endpoint_url,owner,folder,archived,rag,is_important,"
                 "message_count,total_input_tokens,total_output_tokens,last_accessed,created_at"))

(define (serialize r)
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

(define (fetch id)
  (call-with-app-db #:mode 'read-only
    (lambda (c)
      (define rs (query-rows c (string-append "SELECT " cols " FROM sessions WHERE id = ?") id))
      (and (pair? rs) (car rs)))))

;; ---- subcommands -----------------------------------------------------------

(define (cmd-list archived-mode folder limit pretty?)
  (define where
    (string-append
     (cond [(eq? archived-mode #f) "WHERE archived = 0 "]
           [(eq? archived-mode 'only) "WHERE archived = 1 "]
           [else ""])                              ; 'all -> no archived filter
     (if folder (string-append (if (eq? archived-mode 'all) "WHERE " "AND ") "folder = ? ") "")))
  (define params (if folder (list folder) '()))
  (define sql (string-append "SELECT " cols " FROM sessions " where
                             "ORDER BY last_accessed DESC LIMIT ?"))
  (define rows (call-with-app-db #:mode 'read-only
                 (lambda (c) (apply query-rows c sql (append params (list limit))))))
  (emit (map serialize rows) #:pretty? pretty?))

(define (cmd-show id pretty?)
  (define r (fetch id))
  (unless r (fail (format "no session with id ~s" id)))
  (emit (serialize r) #:pretty? pretty?))

(define (set-archived id archived? pretty?)
  (call-with-app-db
   (lambda (c)
     (unless (pair? (query-rows c "SELECT 1 FROM sessions WHERE id = ? LIMIT 1" id))
       (fail (format "no session with id ~s" id)))
     (query-exec c "UPDATE sessions SET archived = ? WHERE id = ?" (if archived? 1 0) id)))
  (emit (hasheq 'ok #t 'id id 'archived archived?) #:pretty? pretty?))

(define (cmd-delete id yes? pretty?)
  (unless yes? (fail "delete is irreversible — pass --yes to confirm"))
  (define snap
    (call-with-app-db
     (lambda (c)
       (define rs (query-rows c (string-append "SELECT " cols " FROM sessions WHERE id = ?") id))
       (unless (pair? rs) (fail (format "no session with id ~s" id)))
       (define s (serialize (car rs)))
       (query-exec c "DELETE FROM sessions WHERE id = ?" id)
       s)))
  (emit (hasheq 'ok #t 'deleted snap) #:pretty? pretty?))

;; ---- arg parsing -----------------------------------------------------------
(define (opt args flag)
  (let loop ([xs args]) (cond [(null? xs) #f]
                              [(and (string=? (car xs) flag) (pair? (cdr xs))) (cadr xs)]
                              [else (loop (cdr xs))])))
(define (int-opt args flag default)
  (define v (opt args flag)) (if v (or (string->number v) default) default))

;; --archived (flag) -> 'all ; --archived only -> 'only ; absent -> #f
(define (archived-mode args)
  (let loop ([xs args])
    (cond [(null? xs) #f]
          [(string=? (car xs) "--archived")
           (if (and (pair? (cdr xs)) (string=? (cadr xs) "only")) 'only 'all)]
          [else (loop (cdr xs))])))

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  (define rest (filter (lambda (a) (not (string=? a "--pretty"))) args))
  (when (null? rest) (fail "missing subcommand: list|show|archive|unarchive|delete" #:code 2))
  (define cmd (car rest))
  (define a (cdr rest))
  (case cmd
    [("list") (cmd-list (archived-mode a) (opt a "--folder") (int-opt a "--limit" 50) pretty?)]
    [("show") (when (null? a) (fail "show needs a SESSION_ID" #:code 2)) (cmd-show (car a) pretty?)]
    [("archive") (when (null? a) (fail "archive needs a SESSION_ID" #:code 2)) (set-archived (car a) #t pretty?)]
    [("unarchive") (when (null? a) (fail "unarchive needs a SESSION_ID" #:code 2)) (set-archived (car a) #f pretty?)]
    [("delete") (when (null? a) (fail "delete needs a SESSION_ID" #:code 2))
                (cmd-delete (car a) (and (member "--yes" a) #t) pretty?)]
    [else (fail (format "unknown subcommand: ~a" cmd) #:code 2)]))

(module+ main
  (run "odysseus-sessions" app-version dispatch))
